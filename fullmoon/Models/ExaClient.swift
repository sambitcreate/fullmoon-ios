//
//  ExaClient.swift
//  fullmoon
//
//  Created by Codex on 2/5/26.
//

import Foundation

enum BoolOr<T: Encodable>: Encodable {
    case bool(Bool)
    case object(T)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeFunc = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeFunc(encoder)
    }
}

struct ExaSearchRequest: Encodable {
    let query: String
    var type: String? = "auto"
    var numResults: Int? = 10
    var userLocation: String? = nil
    var maxAgeHours: Int? = nil

    var contents: Contents? = Contents(
        text: .bool(false),
        highlights: nil,
        summary: nil,
        context: nil
    )

    struct Contents: Encodable {
        var text: BoolOr<TextOptions>?
        var highlights: BoolOr<HighlightsOptions>?
        var summary: BoolOr<SummaryOptions>?
        var context: BoolOr<ContextOptions>?
    }

    struct TextOptions: Encodable {
        var maxCharacters: Int? = nil
        var includeHtmlTags: Bool? = nil
        var verbosity: String? = nil
    }

    struct HighlightsOptions: Encodable {
        var query: String? = nil
        var maxCharacters: Int? = nil
    }

    struct SummaryOptions: Encodable {
        var query: String? = nil
        var schema: [String: AnyEncodable]? = nil
    }

    struct ContextOptions: Encodable {
        var maxCharacters: Int? = nil
    }
}

struct ExaSearchResponse: Decodable {
    let requestId: String
    let results: [ExaResult]
    let searchType: String?
    let context: String?
}

struct ExaResult: Decodable {
    let id: String?
    let url: String
    let title: String?
    let author: String?
    let publishedDate: String?
    let text: String?
    let highlights: [String]?
    let highlightScores: [Double]?
    let summary: String?
    let image: String?
    let favicon: String?
}

final class ExaClient {
    private let apiKey: String
    private let session: URLSession

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func search(query: String, numResults: Int = 10, includeHighlights: Bool = true) async throws -> ExaSearchResponse {
        var requestBody = ExaSearchRequest(query: query, numResults: numResults)
        requestBody.contents = .init(
            text: .bool(false),
            highlights: .bool(includeHighlights),
            summary: nil,
            context: nil
        )

        var request = URLRequest(url: URL(string: "https://api.exa.ai/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw NSError(domain: "ExaHTTPError", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: body])
        }

        return try JSONDecoder().decode(ExaSearchResponse.self, from: data)
    }
}
