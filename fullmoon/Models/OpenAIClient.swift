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

    struct ResponseFormat: Encodable {
        let type: String
        let jsonSchema: JSONSchemaDefinition?

        init(type: String = "json_schema", jsonSchema: JSONSchemaDefinition? = nil) {
            self.type = type
            self.jsonSchema = jsonSchema
        }

        enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    struct JSONSchemaDefinition: Encodable {
        let name: String
        let description: String?
        let schema: JSONSchemaObject

        init(name: String, description: String? = nil, schema: JSONSchemaObject) {
            self.name = name
            self.description = description
            self.schema = schema
        }
    }

    struct JSONSchemaObject: Encodable {
        let type: String
        let properties: [String: JSONProperty]
        let required: [String]
        let additionalProperties: Bool

        init(
            type: String = "object",
            properties: [String: JSONProperty],
            required: [String],
            additionalProperties: Bool = false
        ) {
            self.type = type
            self.properties = properties
            self.required = required
            self.additionalProperties = additionalProperties
        }
    }

    struct JSONProperty: Encodable {
        let type: String
        let description: String?

        init(type: String, description: String? = nil) {
            self.type = type
            self.description = description
        }
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
        let responseFormat: ResponseFormat?

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case stream
            case tools
            case toolChoice = "tool_choice"
            case maxTokens = "max_tokens"
            case responseFormat = "response_format"
        }
    }

    struct ContentPart: Decodable {
        let type: String?
        let text: String?
    }

    enum MessageContent: Decodable {
        case text(String)
        case parts([ContentPart])
        case none

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .none
                return
            }
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            if let parts = try? container.decode([ContentPart].self) {
                self = .parts(parts)
                return
            }
            self = .none
        }

        var flattenedText: String? {
            switch self {
            case let .text(value):
                return value
            case let .parts(parts):
                let text = parts.compactMap(\.text).joined()
                return text.isEmpty ? nil : text
            case .none:
                return nil
            }
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
                let content: MessageContent?
                let reasoningContent: String?
                let toolCalls: [ToolCall]?

                var contentText: String? {
                    content?.flattenedText
                }

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
        return decoded.choices.compactMap { $0.message?.contentText }.joined()
    }

    static func extractChatText(from data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) {
            let text = decoded.choices.compactMap { message in
                let content = message.message?.contentText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !content.isEmpty {
                    return content
                }
                let reasoning = message.message?.reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return reasoning.isEmpty ? nil : reasoning
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

    static func extractJSONTitle(from data: Data) -> String? {
        func cleanedTitle(_ text: String) -> String? {
            var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
            cleaned = cleaned.replacingOccurrences(of: "\n", with: " ")
            cleaned = cleaned.replacingOccurrences(of: "\r", with: " ")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }

        func isPlaceholderTitle(_ text: String) -> Bool {
            let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let disallowed = [
                "string",
                "title",
                "json",
                "object",
                "response",
                "output",
                "text",
                "n/a",
                "none",
                "null",
                "undefined"
            ]
            if disallowed.contains(lower) {
                return true
            }

            let placeholderFragments = [
                "title here",
                "your title",
                "example title",
                "insert title",
                "json object",
                "schema"
            ]
            return placeholderFragments.contains(where: { lower.contains($0) })
        }

        func isReasoningInTitle(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()

            // Reject ellipsis or placeholder-only titles like "..."
            let strippedPunctuation = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?…·-–—"))
            if strippedPunctuation.isEmpty {
                return true
            }

            // Reject titles that are too short
            if trimmed.count < 3 {
                return true
            }

            // Reject if too long (titles should be short)
            if trimmed.count > 80 {
                return true
            }

            // Reject markdown formatting
            if text.contains("**") || text.contains("```") || text.contains("`") {
                return true
            }

            // Reject bullet points (model reasoning artifacts)
            if trimmed.hasPrefix("*") || trimmed.hasPrefix("-") || trimmed.hasPrefix("•") {
                return true
            }

            // Reject if it contains "Input:" or "Output:" (model quoting its analysis)
            if lower.contains("input:") || lower.contains("output:") {
                return true
            }

            // Reject numbered list items like "1. Analyze..." or "2. Identify..."
            if let listRegex = try? NSRegularExpression(pattern: #"^\s*\d+[\.\)]\s+"#, options: []),
               listRegex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) != nil {
                return true
            }

            // Reject common reasoning prefixes
            let reasoningPrefixes = [
                "analyze",
                "identify",
                "determine",
                "extract",
                "consider",
                "first,",
                "next,",
                "then,",
                "finally,",
                "step ",
                "here is",
                "here's",
                "sure,",
                "okay,",
                "certainly",
                "of course",
                "the user",
                "i need to",
                "i should",
                "i will",
                "let me",
                "this is a",
                "based on"
            ]
            if reasoningPrefixes.contains(where: { lower.hasPrefix($0) }) {
                return true
            }

            // Reject common reasoning fragments
            let reasoningFragments = [
                "the constraints",
                "the request",
                "the conversation",
                "json format",
                "json output",
                "generate a title",
                "create a title",
                "provide a title"
            ]
            return reasoningFragments.contains(where: { lower.contains($0) })
        }

        func parseJSONObjectTitle(from text: String) -> String? {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["title"] as? String else {
                return nil
            }
            guard let cleaned = cleanedTitle(title),
                  !isPlaceholderTitle(cleaned),
                  !isReasoningInTitle(cleaned) else {
                return nil
            }
            return cleaned
        }

        func parseEmbeddedJSONTitle(from text: String) -> String? {
            guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
                return nil
            }
            let slice = String(text[start...end])
            guard let title = parseJSONObjectTitle(from: slice) else {
                return nil
            }
            return title
        }

        func parseRegexTitle(from text: String) -> String? {
            let pattern = "\"title\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])+)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return nil
            }
            let range = NSRange(location: 0, length: text.utf16.count)
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.numberOfRanges > 1,
                  let titleRange = Range(match.range(at: 1), in: text) else {
                return nil
            }

            let escaped = String(text[titleRange])
            guard let wrapped = "\"\(escaped)\"".data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(String.self, from: wrapped) else {
                guard let cleaned = cleanedTitle(escaped),
                      !isPlaceholderTitle(cleaned),
                      !isReasoningInTitle(cleaned) else {
                    return nil
                }
                return cleaned
            }
            guard let cleaned = cleanedTitle(decoded),
                  !isPlaceholderTitle(cleaned),
                  !isReasoningInTitle(cleaned) else {
                return nil
            }
            return cleaned
        }

        func isReasoningArtifact(_ text: String) -> Bool {
            let lower = text.lowercased()
            let reasoningPrefixes = [
                "the user wants",
                "the user is asking",
                "the user asked",
                "i need to",
                "i should",
                "i will",
                "let me",
                "this is a request",
                "this request",
                "analyzing",
                "based on",
                "to generate",
                "to create",
                "here is",
                "here's",
                "sure,",
                "okay,",
                "certainly",
                "of course"
            ]
            for prefix in reasoningPrefixes {
                if lower.hasPrefix(prefix) {
                    return true
                }
            }
            let reasoningFragments = [
                "in json format",
                "json output",
                "json response",
                "short title for",
                "title for the conversation",
                "title for this conversation",
                "generate a title",
                "create a title",
                "provide a title"
            ]
            return reasoningFragments.contains(where: { lower.contains($0) })
        }

        func parseTitleFromText(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            // First priority: try to parse JSON object with title field
            if let title = parseJSONObjectTitle(from: trimmed) {
                return title
            }

            let withoutFences = trimmed
                .replacingOccurrences(of: "```json", with: "", options: [.caseInsensitive])
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let title = parseJSONObjectTitle(from: withoutFences) {
                return title
            }

            // Second priority: look for embedded JSON anywhere in the text
            if let title = parseEmbeddedJSONTitle(from: trimmed) {
                return title
            }

            // Third priority: regex extraction of "title": "value"
            if let title = parseRegexTitle(from: trimmed) {
                return title
            }

            // Last resort: use first non-JSON line only if it's not reasoning
            let lines = trimmed
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            
            // Find first line that's not reasoning and not JSON-like
            for line in lines {
                if line.contains("{") || line.contains("}") {
                    continue
                }
                if isReasoningArtifact(line) {
                    continue
                }
                if isReasoningInTitle(line) {
                    continue
                }
                guard let cleaned = cleanedTitle(line),
                      !isPlaceholderTitle(cleaned),
                      !isReasoningInTitle(cleaned) else {
                    continue
                }
                return cleaned
            }

            // Try to extract a title from common patterns in reasoning output
            if let extracted = extractTitleFromReasoning(trimmed) {
                return extracted
            }

            return nil
        }

        // Try to extract actual title from model reasoning output
        func extractTitleFromReasoning(_ text: String) -> String? {
            let lower = text.lowercased()

            // Look for patterns like "Title: Best Characters" or "**Title:** Best Characters"
            let titlePatterns = [
                #"\*\*[Tt]itle:?\*\*\s*[\"']?([^\"'\n]+)[\"']?"#,
                #"[Tt]itle:\s*[\"']?([^\"'\n]+)[\"']?"#,
                #"[Ss]uggested [Tt]itle:\s*[\"']?([^\"'\n]+)[\"']?"#,
                #"[Ff]inal [Tt]itle:\s*[\"']?([^\"'\n]+)[\"']?"#,
                #"[Gg]enerated [Tt]itle:\s*[\"']?([^\"'\n]+)[\"']?"#
            ]

            for pattern in titlePatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
                   match.numberOfRanges > 1,
                   let titleRange = Range(match.range(at: 1), in: text) {
                    let candidate = String(text[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cleaned = cleanedTitle(candidate),
                       !isPlaceholderTitle(cleaned),
                       !isReasoningInTitle(cleaned) {
                        return cleaned
                    }
                }
            }

            return nil
        }

        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            if let raw = String(data: data, encoding: .utf8) {
                return parseTitleFromText(raw)
            }
            return nil
        }

        for choice in decoded.choices {
            if let content = choice.message?.contentText,
               let title = parseTitleFromText(content),
               !title.isEmpty {
                return title
            }
        }

        for choice in decoded.choices {
            if let reasoning = choice.message?.reasoningContent,
               let title = parseTitleFromText(reasoning),
               !title.isEmpty {
                return title
            }
        }

        return nil
    }

    static func extractChatCompletionToolCalls(from data: Data) -> [ToolCall]? {
        guard let decoded = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            return nil
        }
        let toolCalls = decoded.choices.compactMap { $0.message?.toolCalls }.flatMap { $0 }
        return toolCalls.isEmpty ? nil : toolCalls
    }
}
