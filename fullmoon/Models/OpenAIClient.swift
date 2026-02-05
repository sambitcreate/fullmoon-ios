//
//  OpenAIClient.swift
//  fullmoon
//
//  Created by Codex on 2/5/26.
//

import Foundation

enum OpenAIClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case serverError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "invalid api base url"
        case .invalidResponse:
            return "invalid response from server"
        case let .serverError(status, body):
            if body.isEmpty {
                return "server error (\(status))"
            }
            return "server error (\(status)): \(body)"
        }
    }
}

struct OpenAIClient {
    struct Model: Decodable {
        let id: String
    }

    struct ModelsResponse: Decodable {
        let data: [Model]
    }

    struct ChatMessage: Codable {
        let role: String
        let content: String?
        let toolCalls: [ToolCall]?
        let toolCallId: String?

        init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
            self.role = role
            self.content = content
            self.toolCalls = toolCalls
            self.toolCallId = toolCallId
        }

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case toolCalls = "tool_calls"
            case toolCallId = "tool_call_id"
        }
    }

    struct Tool: Encodable {
        let type: String
        let function: ToolFunction

        init(function: ToolFunction) {
            self.type = "function"
            self.function = function
        }
    }

    struct ToolFunction: Encodable {
        let name: String
        let description: String?
        let parameters: JSONSchema
    }

    struct JSONSchema: Encodable {
        let type: String
        let properties: [String: JSONSchemaProperty]
        let required: [String]?
    }

    struct JSONSchemaProperty: Encodable {
        let type: String
        let description: String?
        let enumValues: [String]?
        let minimum: Int?
        let maximum: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case description
            case enumValues = "enum"
            case minimum
            case maximum
        }
    }

    struct ToolCall: Codable {
        let id: String?
        let type: String?
        let function: ToolCallFunction
    }

    struct ToolCallFunction: Codable {
        let name: String
        let arguments: String
    }

    struct ToolCallDelta: Decodable {
        let index: Int?
        let id: String?
        let type: String?
        let function: ToolCallFunctionDelta?
    }

    struct ToolCallFunctionDelta: Decodable {
        let name: String?
        let arguments: String?
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let maxTokens: Int?
        let stream: Bool
        let tools: [Tool]?
        let toolChoice: String?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case stream
            case tools
            case toolChoice = "tool_choice"
            case maxTokens = "max_tokens"
        }
    }

    struct ChatStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let toolCalls: [ToolCallDelta]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                }
            }

            let delta: Delta?
        }

        let choices: [Choice]
    }

    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?
                let toolCalls: [ToolCall]?

                enum CodingKeys: String, CodingKey {
                    case content
                    case toolCalls = "tool_calls"
                    case reasoningContent = "reasoning_content"
                }
            }

            let message: Message?
        }

        let choices: [Choice]
    }

    enum StreamEvent {
        case delta(String)
        case toolCallDelta(ToolCallDelta)
        case done
    }

    struct ToolCallAccumulator {
        struct Partial {
            var id: String?
            var type: String?
            var name: String?
            var arguments: String = ""
        }

        private var store: [Int: Partial] = [:]

        mutating func append(_ delta: ToolCallDelta) {
            let index = delta.index ?? 0
            var partial = store[index] ?? Partial()
            if let id = delta.id {
                partial.id = id
            }
            if let type = delta.type {
                partial.type = type
            }
            if let name = delta.function?.name {
                partial.name = name
            }
            if let args = delta.function?.arguments {
                partial.arguments += args
            }
            store[index] = partial
        }

        func buildToolCalls() -> [ToolCall] {
            store
                .sorted { $0.key < $1.key }
                .compactMap { _, partial in
                    guard let name = partial.name else { return nil }
                    return ToolCall(
                        id: partial.id,
                        type: partial.type,
                        function: ToolCallFunction(name: name, arguments: partial.arguments)
                    )
                }
        }
    }

    private struct APIErrorResponse: Decodable {
        struct APIError: Decodable {
            let message: String
        }

        let error: APIError
    }

    static func normalizedBaseURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://\(trimmed)"
        }
        return URL(string: trimmed)
    }

    func listModels(baseURL: URL, apiKey: String?) async throws -> [String] {
        var request = OpenAIClient.makeModelsRequest(baseURL: baseURL, apiKey: apiKey)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = OpenAIClient.extractErrorMessage(from: data)
            throw OpenAIClientError.serverError(status: httpResponse.statusCode, body: message ?? "")
        }

        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return decoded.data.map(\.id).sorted()
    }

    static func makeModelsRequest(baseURL: URL, apiKey: String?) -> URLRequest {
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyAuthHeader(apiKey, to: &request)
        return request
    }

    static func makeChatRequest(baseURL: URL, apiKey: String?, body: ChatRequest) throws -> URLRequest {
        let url = baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthHeader(apiKey, to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    static func parseStreamLine(_ line: String) throws -> [StreamEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return [] }
        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return [.done]
        }
        guard let data = payload.data(using: .utf8) else { return [] }
        let chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
        var events: [StreamEvent] = []
        let deltaText = chunk.choices.compactMap { $0.delta?.content }.joined()
        if !deltaText.isEmpty {
            events.append(.delta(deltaText))
        }
        for choice in chunk.choices {
            if let toolCalls = choice.delta?.toolCalls {
                for toolCall in toolCalls {
                    events.append(.toolCallDelta(toolCall))
                }
            }
        }
        return events
    }

    static func applyAuthHeader(_ apiKey: String?, to request: inout URLRequest) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    }

    static func extractErrorMessage(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(APIErrorResponse.self, from: data) {
            return decoded.error.message
        }
        let raw = String(data: data, encoding: .utf8)
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractChatCompletionContent(from data: Data) -> String? {
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            return nil
        }
        return decoded.choices.compactMap { $0.message?.content }.joined()
    }

    static func extractChatText(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) {
            let text = decoded.choices.compactMap { message in
                message.message?.content?.isEmpty == false
                    ? message.message?.content
                    : message.message?.reasoningContent
            }.joined()
            if !text.isEmpty {
                return text
            }
        }

        if let text = String(data: data, encoding: .utf8), text.contains("data:") {
            var outputText = ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            for line in lines {
                let events = (try? parseStreamLine(String(line))) ?? []
                for event in events {
                    if case let .delta(delta) = event {
                        outputText += delta
                    }
                }
            }
            if !outputText.isEmpty {
                return outputText
            }
        }

        return extractChatCompletionContent(from: data) ?? ""
    }

    static func extractChatCompletionToolCalls(from data: Data) -> [ToolCall]? {
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            return nil
        }
        let toolCalls = decoded.choices.compactMap { $0.message?.toolCalls }.flatMap { $0 }
        return toolCalls.isEmpty ? nil : toolCalls
    }
}
