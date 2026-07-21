import Foundation

/// Anthropic (Claude) implementation of `AIProviderProtocol`.
///
/// Uses raw `URLSession` + `async/await` against the Messages API — there is no
/// official Anthropic SDK for Swift, so raw HTTP is the correct integration.
/// JSON encoding/decoding matches Anthropic's Messages API schema exactly.
///
/// Notes:
/// - Model defaults to `claude-opus-4-8` (Anthropic's current Opus-tier model).
/// - No `temperature` / `top_p` is sent: those are rejected (HTTP 400) on
///   Opus 4.7/4.8. Behaviour is steered via the mode's system prompt instead.
final class ClaudeService: AIProviderProtocol {

    let providerID: AIProviderID = .claude

    private let model: String
    private let maxTokens: Int
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let session: URLSession

    init(model: String = "claude-opus-4-8", maxTokens: Int = 4096) {
        self.model = model
        self.maxTokens = maxTokens

        // Hard 10-second ceiling per the spec's timeout requirement.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: – AIProviderProtocol

    func process(text: String, mode: ProcessingMode) async throws -> String {
        guard let apiKey = try KeychainManager.shared.apiKey(for: providerID), !apiKey.isEmpty else {
            throw AIError.missingAPIKey(providerID)
        }

        let request = try makeRequest(apiKey: apiKey, text: text, mode: mode)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw AIError.networkTimeout
        } catch let urlError as URLError {
            throw AIError.network(urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }

        try Self.validate(status: http.statusCode, data: data, headers: http)
        return try Self.parseText(from: data)
    }

    // MARK: – Request building

    private func makeRequest(apiKey: String, text: String, mode: ProcessingMode) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

        let body = MessagesRequest(
            model: model,
            maxTokens: maxTokens,
            system: mode.systemPrompt,
            messages: [.init(role: "user", content: text)]
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: – Response handling

    private static func validate(status: Int, data: Data, headers: HTTPURLResponse) throws {
        switch status {
        case 200:
            return
        case 401:
            throw AIError.invalidAPIKey
        case 429:
            let retryAfter = (headers.value(forHTTPHeaderField: "retry-after")).flatMap { Int($0) }
            throw AIError.rateLimited(retryAfter: retryAfter)
        case 400:
            throw AIError.badRequest(decodeErrorMessage(from: data) ?? "invalid request")
        case 500...599:
            throw AIError.serverError(status: status)
        default:
            throw AIError.badRequest(decodeErrorMessage(from: data) ?? "HTTP \(status)")
        }
    }

    private static func parseText(from data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw AIError.invalidResponse
        }

        // A refusal returns 200 with no text block – surface it as a clear error.
        if decoded.stopReason == "refusal" {
            throw AIError.badRequest("The model declined this request.")
        }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw AIError.invalidResponse }
        return text
    }

    private static func decodeErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(MessagesErrorResponse.self, from: data))?.error.message
    }
}

// MARK: – Anthropic Messages API schema

private struct MessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: String
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

private struct MessagesResponse: Decodable {
    let content: [ContentBlock]
    let stopReason: String?

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

private struct MessagesErrorResponse: Decodable {
    let error: Detail
    struct Detail: Decodable {
        let type: String
        let message: String
    }
}
