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

    func generateCloud(modelName: String, thread: Thread, systemPrompt: String, apiBaseURL: String, apiKey: String) async -> String {
        guard !running else { return "" }

        running = true
        cancelled = false
        output = ""
        stat = ""
        startTime = Date()
        isThinking = false
        thinkingTime = nil

        defer {
            running = false
            cloudRequestTask = nil
        }

        do {
            guard let baseURL = OpenAIClient.normalizedBaseURL(from: apiBaseURL) else {
                output = "Missing or invalid API base URL."
                return output
            }

            let messages = makeOpenAIChatMessages(thread: thread, systemPrompt: systemPrompt)
            let requestBody = OpenAIClient.ChatRequest(
                model: modelName,
                messages: messages,
                temperature: Double(generateParameters.temperature),
                maxTokens: generateParameters.maxTokens,
                stream: true
            )
            let request = try OpenAIClient.makeChatRequest(baseURL: baseURL, apiKey: apiKey, body: requestBody)

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

            streamLoop: for try await line in bytes.lines {
                if cancelled {
                    break streamLoop
                }

                if let event = try OpenAIClient.parseStreamLine(line) {
                    switch event {
                    case .done:
                        break streamLoop
                    case let .delta(text):
                        outputText += text
                        chunkCount += 1
                        if chunkCount % displayEveryNTokens == 0 {
                            output = outputText
                        }
                    }
                } else {
                    let trimmed = String(line).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        rawResponse += trimmed
                    }
                }
            }

            if outputText.isEmpty, let data = rawResponse.data(using: .utf8) {
                if let fallback = OpenAIClient.extractChatCompletionContent(from: data) {
                    outputText = fallback
                }
            }

            if outputText != output {
                output = outputText
            }
            thinkingTime = elapsedTime

        } catch {
            output = "Failed: \(error.localizedDescription)"
        }

        return output
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
