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
        exaAPIKey: String
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

        defer {
            running = false
            cloudRequestTask = nil
        }

        do {
            guard let baseURL = OpenAIClient.normalizedBaseURL(from: apiBaseURL) else {
                output = "Missing or invalid API base URL."
                return output
            }

            let trimmedExaKey = exaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let webSearchAvailable = webSearchEnabled && !trimmedExaKey.isEmpty
            let tools = webSearchAvailable ? [webSearchTool, exaSearchTool] : nil
            let toolChoice = webSearchAvailable ? "auto" : nil

            var messages = makeOpenAIChatMessages(thread: thread, systemPrompt: systemPrompt)
            var outputText = ""
            var toolIterations = 0
            let maxToolIterations = webSearchAvailable ? 2 : 0

            while true {
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

                outputText = result.text
                var toolCalls = result.toolCalls

                if outputText.isEmpty, !result.rawResponse.isEmpty, let data = result.rawResponse.data(using: .utf8) {
                    if let fallback = OpenAIClient.extractChatCompletionContent(from: data) {
                        outputText = fallback
                    }
                    if toolCalls.isEmpty, let fallbackToolCalls = OpenAIClient.extractChatCompletionToolCalls(from: data) {
                        toolCalls = fallbackToolCalls
                    }
                }

                if !toolCalls.isEmpty {
                    if webSearchAvailable, toolIterations < maxToolIterations {
                        output = "Searching the web..."
                        let toolMessages = await handleToolCalls(toolCalls, apiKey: trimmedExaKey)
                        messages.append(.init(role: Role.assistant.rawValue, content: nil, toolCalls: toolCalls))
                        messages.append(contentsOf: toolMessages)
                        lastUsedWebSearch = true
                        toolIterations += 1
                        continue
                    } else if outputText.isEmpty {
                        outputText = webSearchAvailable
                            ? "Web search tool budget reached for this message."
                            : "Web search is disabled or missing an EXA API key."
                    }
                }

                if outputText != output {
                    output = outputText
                }
                thinkingTime = elapsedTime
                break
            }
        } catch {
            output = "Failed: \(error.localizedDescription)"
        }

        return output
    }

    private struct WebSearchToolArguments: Decodable {
        let query: String
        let numResults: Int?

        enum CodingKeys: String, CodingKey {
            case query
            case numResults = "num_results"
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

    private func handleToolCalls(_ toolCalls: [OpenAIClient.ToolCall], apiKey: String) async -> [OpenAIClient.ChatMessage] {
        var messages: [OpenAIClient.ChatMessage] = []

        for call in toolCalls {
            let toolCallId = call.id ?? UUID().uuidString
            if call.function.name == "web_search" || call.function.name == "exa_search" {
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

        return messages
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
