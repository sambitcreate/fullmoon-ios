//
//  LLMEvaluator.swift
//  fullmoon
//
//  Created by Jordan Singer on 10/4/24.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXRandom
import SwiftUI

enum LLMEvaluatorError: Error {
    case modelNotFound(String)
}

enum AgentActivityType: Equatable {
    case thinking
    case searching(query: String)
}

struct AgentActivity: Identifiable, Equatable {
    let id = UUID()
    let type: AgentActivityType
    let timestamp = Date()
    
    var description: String {
        switch type {
        case .thinking:
            return "thinking..."
        case .searching(let query):
            return "searching: \(query)"
        }
    }
}

@Observable
@MainActor
class LLMEvaluator {
    var running = false
    var cancelled = false
    var output = ""
    var modelInfo = ""
    var stat = ""
    var progress = 0.0
    var thinkingTime: TimeInterval?
    var collapsed: Bool = false
    var isThinking: Bool = false
    var lastUsedWebSearch: Bool = false
    var agentActivities: [AgentActivity] = []
    var isFinalizingAnswer: Bool = false

    var elapsedTime: TimeInterval? {
        if let startTime {
            return Date().timeIntervalSince(startTime)
        }

        return nil
    }

    private var startTime: Date?

    var modelConfiguration = ModelConfiguration.defaultModel
    private var cloudRequestTask: URLSessionTask?

    func switchModel(_ model: ModelConfiguration) async {
        progress = 0.0 // reset progress
        loadState = .idle
        modelConfiguration = model
        _ = try? await load(modelName: model.name)
    }

    /// parameters controlling the output
    let generateParameters = GenerateParameters(maxTokens: 4096, temperature: 0.5)
    private let titleGenerateParameters = GenerateParameters(maxTokens: 64, temperature: 0.2)

    /// update the display every N tokens -- 4 looks like it updates continuously
    /// and is low overhead.  observed ~15% reduction in tokens/s when updating
    /// on every token
    let displayEveryNTokens = 4

    enum LoadState {
        case idle
        case loaded(ModelContainer)
    }

    var loadState = LoadState.idle

    /// load and return the model -- can be called multiple times, subsequent calls will
    /// just return the loaded model
    func load(modelName: String) async throws -> ModelContainer {
        guard let model = ModelConfiguration.getModelByName(modelName) else {
            throw LLMEvaluatorError.modelNotFound(modelName)
        }

        switch loadState {
        case .idle:
            // limit the buffer cache
            Memory.cacheLimit = 20 * 1024 * 1024

            let modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: model) {
                [modelConfiguration] progress in
                Task { @MainActor in
                    self.modelInfo =
                        "Downloading \(modelConfiguration.name): \(Int(progress.fractionCompleted * 100))%"
                    self.progress = progress.fractionCompleted
                }
            }
            modelInfo =
                "Loaded \(modelConfiguration.id).  Weights: \(Memory.activeMemory / 1024 / 1024)M"
            loadState = .loaded(modelContainer)
            return modelContainer

        case let .loaded(modelContainer):
            return modelContainer
        }
    }

    func stop() {
        isThinking = false
        cancelled = true
        cloudRequestTask?.cancel()
        cloudRequestTask = nil
        agentActivities.removeAll()
    }
    
    private func addActivity(_ type: AgentActivityType) {
        let activity = AgentActivity(type: type)
        agentActivities.append(activity)
        // Don't append to output - activities will be displayed separately with animations
    }
    
    private func clearActivities() {
        agentActivities.removeAll()
    }

    func generate(modelName: String, thread: Thread, systemPrompt: String) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        lastUsedWebSearch = false
        startTime = Date()

        do {
            let modelContainer = try await load(modelName: modelName)

            // augment the prompt as needed
            let promptHistory = await modelContainer.configuration.getPromptHistory(thread: thread, systemPrompt: systemPrompt)

            if await modelContainer.configuration.modelType == .reasoning {
                isThinking = true
            }

            // each time you generate you will get something new
            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

            let result = try await modelContainer.perform { (context: ModelContext) async throws -> (String, Double) in
                let input = try await context.processor.prepare(input: .init(messages: promptHistory))
                let stream = try MLXLMCommon.generate(
                    input: input, cache: nil, parameters: generateParameters, context: context
                )

                var outputText = ""
                var chunkCount = 0
                var tokensPerSecond: Double?

                for await generation in stream {
                    if let chunk = generation.chunk {
                        outputText += chunk
                        chunkCount += 1

                        if chunkCount % displayEveryNTokens == 0 {
                            let currentOutput = outputText
                            Task { @MainActor in
                                self.output = currentOutput
                            }
                        }
                    } else if let info = generation.info {
                        tokensPerSecond = info.tokensPerSecond
                    }

                    let cancelled = await MainActor.run { self.cancelled }
                    if cancelled {
                        break
                    }
                }

                return (outputText, tokensPerSecond ?? 0)
            }

            // update the text if needed, e.g. we haven't displayed because of displayEveryNTokens
            if result.0 != output {
                output = result.0
            }
            stat = " Tokens/second: \(String(format: "%.3f", result.1))"

        } catch {
            output = "Failed: \(error)"
        }

        running = false
        return output
    }

    func generateCloud(
        modelName: String,
        thread: Thread,
        systemPrompt: String,
        apiBaseURL: String,
        apiKey: String,
        webSearchEnabled: Bool,
        exaAPIKey: String,
        thinkingModeEnabled: Bool = false
    ) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        stat = ""
        startTime = Date()
        isThinking = false
        thinkingTime = nil
        lastUsedWebSearch = false
        isFinalizingAnswer = false
        clearActivities()

        defer {
            running = false
            cloudRequestTask = nil
            isFinalizingAnswer = false
        }

        do {
            guard let baseURL = OpenAIClient.normalizedBaseURL(from: apiBaseURL) else {
                output = "Missing or invalid API base URL."
                return output
            }

            let trimmedExaKey = exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let webSearchAvailable = webSearchEnabled && !trimmedExaKey.isEmpty
            // Only provide finalize_answer tool in thinking mode (agentic workflow)
            // Without thinking mode, model should return text naturally after searches
            let tools: [OpenAIClient.Tool]? = {
                guard webSearchAvailable else { return nil }
                if thinkingModeEnabled {
                    return [webSearchTool, exaSearchTool, finalizeAnswerTool]
                } else {
                    return [webSearchTool, exaSearchTool]
                }
            }()
            let toolChoice = webSearchAvailable ? "auto" : nil

            var messages = makeOpenAIChatMessages(thread: thread, systemPrompt: systemPrompt)
            var currentIterationText = ""
            var toolIterations = 0
            // Thinking mode expects an agentic loop with multiple iterations for research
            // Without thinking mode, we limit to 2 iterations to prevent runaway costs
            // The model should call finalize_answer when done; limit is a safety net
            let baseLimit = thinkingModeEnabled ? 8 : 2
            let maxLimit = thinkingModeEnabled ? 12 : 2
            var maxToolIterations = webSearchAvailable ? baseLimit : 0

            while true {
                // Add thinking activity at the start of each iteration (after the first)
                if toolIterations > 0 {
                    addActivity(.thinking)
                }
                
                let requestBody = OpenAIClient.ChatRequest(
                    model: modelName,
                    messages: messages,
                    temperature: Double(generateParameters.temperature),
                    maxTokens: generateParameters.maxTokens,
                    stream: true,
                    tools: tools,
                    toolChoice: toolChoice
                )
                let request = try OpenAIClient.makeChatRequest(baseURL: baseURL, apiKey: apiKey, body: requestBody)
                let result = try await streamChatResponse(request: request)

                currentIterationText = result.text
                var toolCalls = result.toolCalls

                if currentIterationText.isEmpty, !result.rawResponse.isEmpty, let data = result.rawResponse.data(using: .utf8) {
                    if let fallback = OpenAIClient.extractChatCompletionContent(from: data) {
                        currentIterationText = fallback
                    }
                    if toolCalls.isEmpty, let fallbackToolCalls = OpenAIClient.extractChatCompletionToolCalls(from: data) {
                        toolCalls = fallbackToolCalls
                    }
                }

                // Don't overwrite output on subsequent iterations - activities are already appended
                // Only update if we have new text from this iteration
                if !currentIterationText.isEmpty && (toolIterations == 0 || !output.contains(currentIterationText)) {
                    if toolIterations == 0 {
                        // First iteration - set the initial output
                        output = currentIterationText
                    }
                    // Note: activities are added via addActivity() which appends to output
                }

                if !toolCalls.isEmpty {
                    if webSearchAvailable, toolIterations < maxToolIterations {
                        let toolResult = await handleToolCalls(toolCalls, apiKey: trimmedExaKey)
                        
                        // Check if finalize_answer was called
                        if let finalAnswer = toolResult.finalAnswer {
                            // Model signaled completion with finalize_answer
                            isFinalizingAnswer = true
                            if !finalAnswer.isEmpty {
                                output += "\n\n" + finalAnswer
                            }
                            thinkingTime = elapsedTime
                            break
                        }
                        
                        // Continue with search tools
                        messages.append(.init(role: Role.assistant.rawValue, content: currentIterationText.isEmpty ? nil : currentIterationText, toolCalls: toolCalls))
                        messages.append(contentsOf: toolResult.messages)
                        lastUsedWebSearch = true
                        toolIterations += 1
                        
                        // Dynamic limit extension: if we've hit base limit but model is still searching
                        // (not trying to finalize), allow up to maxLimit
                        if toolIterations >= baseLimit && toolIterations < maxLimit && webSearchAvailable {
                            maxToolIterations = maxLimit
                        }
                        
                        continue
                    } else {
                        // Hit budget limit - make one final request WITHOUT tools to get answer
                        messages.append(.init(role: Role.assistant.rawValue, content: nil, toolCalls: toolCalls))
                        messages.append(.init(role: Role.system.rawValue, content: "Please provide your final answer based on the search results you've gathered. Do not use any more tools."))
                        
                        let finalRequestBody = OpenAIClient.ChatRequest(
                            model: modelName,
                            messages: messages,
                            temperature: Double(generateParameters.temperature),
                            maxTokens: generateParameters.maxTokens,
                            stream: true,
                            tools: nil,  // No tools for final response
                            toolChoice: nil
                        )
                        let finalRequest = try OpenAIClient.makeChatRequest(baseURL: baseURL, apiKey: apiKey, body: finalRequestBody)
                        let finalResult = try await streamChatResponse(request: finalRequest)
                        
                        currentIterationText = finalResult.text
                        if !currentIterationText.isEmpty {
                            isFinalizingAnswer = true
                            if toolIterations > 0 && !output.contains(currentIterationText) {
                                output += "\n\n" + currentIterationText
                            } else if toolIterations == 0 {
                                output = currentIterationText
                            }
                        }
                    }
                }

                // Final iteration - append any new text if we haven't already
                if !currentIterationText.isEmpty && toolIterations > 0 && !output.contains(currentIterationText) {
                    isFinalizingAnswer = true
                    output += "\n\n" + currentIterationText
                }
                
                thinkingTime = elapsedTime
                break
            }
        } catch {
            output = "Failed: \(error.localizedDescription)"
        }

        return output
    }

    func generateTitle(modelName: String, thread: Thread, systemPrompt: String) async -> String {
        let fallback = lastUserMessageText(from: thread).flatMap(fallbackTitle(from:))
        do {
            let modelContainer = try await load(modelName: modelName)
            let promptHistory = await modelContainer.configuration.getPromptHistory(
                thread: thread,
                systemPrompt: systemPrompt
            )

            MLXRandom.seed(UInt64(Date.timeIntervalSinceReferenceDate * 1000))

            let result = try await modelContainer.perform { (context: ModelContext) async throws -> String in
                let input = try await context.processor.prepare(input: .init(messages: promptHistory))
                let stream = try MLXLMCommon.generate(
                    input: input, cache: nil, parameters: titleGenerateParameters, context: context
                )
                var outputText = ""
                for await generation in stream {
                    if let chunk = generation.chunk {
                        outputText += chunk
                    }
                    if Task.isCancelled {
                        break
                    }
                }
                return outputText
            }

            let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return fallback ?? ""
            }
            return result
        } catch {
            return fallback ?? ""
        }
    }

    func generateCloudTitle(
        modelName: String,
        thread: Thread,
        systemPrompt: String,
        apiBaseURL: String,
        apiKey: String
    ) async -> String {
        let fallback = lastUserMessageText(from: thread).flatMap(fallbackTitle(from:))

        guard let baseURL = OpenAIClient.normalizedBaseURL(from: apiBaseURL) else {
            return fallback ?? ""
        }

        let messages = makeOpenAIChatMessages(thread: thread, systemPrompt: systemPrompt)
        let requestBody = OpenAIClient.ChatRequest(
            model: modelName,
            messages: messages,
            temperature: Double(titleGenerateParameters.temperature),
            maxTokens: titleGenerateParameters.maxTokens,
            stream: false,
            tools: nil,
            toolChoice: nil
        )

        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            do {
                var request = try OpenAIClient.makeChatRequest(baseURL: baseURL, apiKey: apiKey, body: requestBody)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
                request.timeoutInterval = 20

                let (data, _) = try await requestChatResponseData(request: request)
                let responseText = OpenAIClient.extractJSONTitle(from: data) ?? OpenAIClient.extractChatText(from: data)
                let trimmed = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    print("Title generation received \(trimmed.count) chars for model: \(modelName)")
                    return responseText
                }
            } catch {
                if attempt == maxAttempts {
                    break
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        return fallback ?? ""
    }

    private struct WebSearchToolArguments: Decodable {
        let query: String
        let numResults: Int?

        enum CodingKeys: String, CodingKey {
            case query
            case numResults = "num_results"
        }
    }
    
    private struct FinalizeAnswerArguments: Decodable {
        let answerMarkdown: String
        let usedEvidenceIds: [String]?
        let openQuestions: [String]?
        
        enum CodingKeys: String, CodingKey {
            case answerMarkdown = "answer_markdown"
            case usedEvidenceIds = "used_evidence_ids"
            case openQuestions = "open_questions"
        }
    }

    private struct WebSearchToolResult: Encodable {
        struct Result: Encodable {
            let title: String?
            let url: String
            let author: String?
            let publishedDate: String?
            let snippet: String?
            let highlights: [String]?
        }

        let query: String
        let results: [Result]
    }

    private struct ToolErrorPayload: Encodable {
        let error: String
    }

    private struct CloudStreamResult {
        let text: String
        let rawResponse: String
        let toolCalls: [OpenAIClient.ToolCall]
    }

    private var webSearchTool: OpenAIClient.Tool {
        OpenAIClient.Tool(
            function: .init(
                name: "web_search",
                description: "Search the web for up-to-date information.",
                parameters: .init(
                    type: "object",
                    properties: [
                        "query": .init(
                            type: "string",
                            description: "The search query.",
                            enumValues: nil,
                            minimum: nil,
                            maximum: nil
                        ),
                        "num_results": .init(
                            type: "integer",
                            description: "Number of results to return (1-10).",
                            enumValues: nil,
                            minimum: 1,
                            maximum: 10
                        )
                    ],
                    required: ["query"]
                )
            )
        )
    }

    private var exaSearchTool: OpenAIClient.Tool {
        OpenAIClient.Tool(
            function: .init(
                name: "exa_search",
                description: "Search the web with Exa. Alias of web_search.",
                parameters: webSearchTool.function.parameters
            )
        )
    }
    
    private var finalizeAnswerTool: OpenAIClient.Tool {
        OpenAIClient.Tool(
            function: .init(
                name: "finalize_answer",
                description: "Submit your final answer when you have gathered enough information. You MUST use this tool to complete your response.",
                parameters: .init(
                    type: "object",
                    properties: [
                        "answer_markdown": .init(
                            type: "string",
                            description: "Your final answer in markdown format. This will be shown to the user.",
                            enumValues: nil,
                            minimum: nil,
                            maximum: nil
                        ),
                        "used_evidence_ids": .init(
                            type: "array",
                            description: "Optional: Evidence IDs you referenced (for future use).",
                            enumValues: nil,
                            minimum: nil,
                            maximum: nil
                        ),
                        "open_questions": .init(
                            type: "array",
                            description: "Optional: Any remaining questions or uncertainties.",
                            enumValues: nil,
                            minimum: nil,
                            maximum: nil
                        )
                    ],
                    required: ["answer_markdown"]
                )
            )
        )
    }

    private func streamChatResponse(request: URLRequest) async throws -> CloudStreamResult {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        cloudRequestTask = bytes.task

        guard (200..<300).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw OpenAIClientError.serverError(status: httpResponse.statusCode, body: body)
        }

        var outputText = ""
        var chunkCount = 0
        var rawResponse = ""
        var toolAccumulator = OpenAIClient.ToolCallAccumulator()

        streamLoop: for try await line in bytes.lines {
            if cancelled {
                break streamLoop
            }

            let events = try OpenAIClient.parseStreamLine(line)
            if events.isEmpty {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    rawResponse += trimmed
                }
                continue
            }

            for event in events {
                switch event {
                case .done:
                    break streamLoop
                case let .delta(text):
                    outputText += text
                    chunkCount += 1
                    if chunkCount % displayEveryNTokens == 0 {
                        output = outputText
                    }
                case let .toolCallDelta(delta):
                    toolAccumulator.append(delta)
                }
            }
        }

        return CloudStreamResult(
            text: outputText,
            rawResponse: rawResponse,
            toolCalls: toolAccumulator.buildToolCalls()
        )
    }

    private func streamChatResponseText(request: URLRequest) async throws -> String {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw OpenAIClientError.serverError(status: httpResponse.statusCode, body: body)
        }

        var outputText = ""
        var rawResponse = ""

        streamLoop: for try await line in bytes.lines {
            if Task.isCancelled {
                break streamLoop
            }

            let events = try OpenAIClient.parseStreamLine(line)
            if events.isEmpty {
                let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    rawResponse += trimmed
                }
                continue
            }

            for event in events {
                if case let .delta(text) = event {
                    outputText += text
                }
            }
        }

        if outputText.isEmpty, !rawResponse.isEmpty, let data = rawResponse.data(using: .utf8) {
            if let fallback = OpenAIClient.extractChatCompletionContent(from: data) {
                outputText = fallback
            }
        }

        return outputText
    }

    private func requestChatResponseText(request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIClientError.serverError(status: httpResponse.statusCode, body: body)
        }

        return OpenAIClient.extractChatText(from: data)
    }

    private func lastUserMessageText(from thread: Thread) -> String? {
        guard let lastUser = thread.sortedMessages.last(where: { $0.role == .user }) else {
            return nil
        }
        let trimmed = lastUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func fallbackTitle(from text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let tokens = cleaned
            .split { $0.isWhitespace }
            .map(String.init)
        let limited = tokens.prefix(8).joined(separator: " ")
        return limited.isEmpty ? nil : limited
    }

    private func requestChatResponseData(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIClientError.serverError(status: httpResponse.statusCode, body: body)
        }
        return (data, httpResponse)
    }

    private struct ToolCallResult {
        let messages: [OpenAIClient.ChatMessage]
        let finalAnswer: String?
    }
    
    private func handleToolCalls(_ toolCalls: [OpenAIClient.ToolCall], apiKey: String) async -> ToolCallResult {
        var messages: [OpenAIClient.ChatMessage] = []
        var finalAnswer: String? = nil

        for call in toolCalls {
            let toolCallId = call.id ?? UUID().uuidString
            
            if call.function.name == "finalize_answer" {
                guard let data = call.function.arguments.data(using: .utf8) else {
                    let payload = ToolErrorPayload(error: "invalid tool arguments")
                    messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
                    continue
                }
                
                do {
                    let args = try JSONDecoder().decode(FinalizeAnswerArguments.self, from: data)
                    finalAnswer = args.answerMarkdown
                    
                    // Send success response back to model
                    let successPayload = ["status": "success", "message": "Answer finalized"]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: successPayload),
                       let jsonString = String(data: jsonData, encoding: .utf8) {
                        messages.append(.init(role: "tool", content: jsonString, toolCallId: toolCallId))
                    }
                } catch {
                    let payload = ToolErrorPayload(error: error.localizedDescription)
                    messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
                }
            } else if call.function.name == "web_search" || call.function.name == "exa_search" {
                guard let data = call.function.arguments.data(using: .utf8) else {
                    let payload = ToolErrorPayload(error: "invalid tool arguments")
                    messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
                    continue
                }

                do {
                    let args = try JSONDecoder().decode(WebSearchToolArguments.self, from: data)
                    let trimmedQuery = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedQuery.isEmpty else {
                        let payload = ToolErrorPayload(error: "missing query")
                        messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
                        continue
                    }

                    // Add search activity with the actual query
                    addActivity(.searching(query: trimmedQuery))
                    
                    let limit = min(max(args.numResults ?? 5, 1), 10)
                    let client = ExaClient(apiKey: apiKey)
                    let response = try await client.search(query: trimmedQuery, numResults: limit, includeHighlights: true)

                    let results = response.results.map { result in
                        WebSearchToolResult.Result(
                            title: result.title,
                            url: result.url,
                            author: result.author,
                            publishedDate: result.publishedDate,
                            snippet: snippet(from: result),
                            highlights: result.highlights
                        )
                    }

                    let payload = WebSearchToolResult(query: trimmedQuery, results: results)
                    messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
                } catch {
                    let payload = ToolErrorPayload(error: error.localizedDescription)
                    messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
                }
            } else {
                let payload = ToolErrorPayload(error: "unsupported tool: \(call.function.name)")
                messages.append(.init(role: "tool", content: encodePayload(payload), toolCallId: toolCallId))
            }
        }

        return ToolCallResult(messages: messages, finalAnswer: finalAnswer)
    }

    private func snippet(from result: ExaResult) -> String? {
        let candidate = result.highlights?.first ?? result.summary ?? result.text
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let maxLength = 400
        if text.count <= maxLength {
            return text
        }
        return String(text.prefix(maxLength)) + "..."
    }

    private func encodePayload<T: Encodable>(_ payload: T) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(payload), let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "{}"
    }

    private func makeOpenAIChatMessages(thread: Thread, systemPrompt: String) -> [OpenAIClient.ChatMessage] {
        var messages: [OpenAIClient.ChatMessage] = []
        let trimmedSystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystemPrompt.isEmpty {
            messages.append(.init(role: Role.system.rawValue, content: trimmedSystemPrompt))
        }

        for message in thread.sortedMessages {
            messages.append(.init(role: message.role.rawValue, content: message.content))
        }

        return messages
    }
}
