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
        let content: String
    }

    struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let temperature: Double?
        let maxTokens: Int?
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case stream
            case maxTokens = "max_tokens"
        }
    }

    struct ChatStreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
            }

            let delta: Delta?
        }

        let choices: [Choice]
    }

    struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message?
        }

        let choices: [Choice]
    }

    enum StreamEvent {
        case delta(String)
        case done
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

    static func parseStreamLine(_ line: String) throws -> StreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return .done
        }
        guard let data = payload.data(using: .utf8) else { return nil }
        let chunk = try JSONDecoder().decode(ChatStreamChunk.self, from: data)
        let delta = chunk.choices.compactMap { $0.delta?.content }.joined()
        guard !delta.isEmpty else { return nil }
        return .delta(delta)
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
}
