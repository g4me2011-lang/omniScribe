import Foundation

/// Identifies which LLM backend a request should route to.
///
/// The `rawValue` doubles as the Keychain account name, so it must stay stable
/// across releases (changing it would orphan a user's stored key).
enum AIProviderID: String, CaseIterable, Codable {
    case claude
    case gemini
    case openai

    var displayName: String {
        switch self {
        case .claude: return "Claude (Anthropic)"
        case .gemini: return "Gemini (Google)"
        case .openai: return "GPT (OpenAI)"
        }
    }
}

/// Errors surfaced by any AI provider. Each carries a user-facing message so the
/// HUD/Settings can display it without a big `switch` at the call site.
enum AIError: LocalizedError, Equatable {
    case missingAPIKey(AIProviderID)
    case invalidAPIKey
    case rateLimited(retryAfter: Int?)
    case networkTimeout
    case network(String)
    case badRequest(String)
    case serverError(status: Int)
    case invalidResponse
    case notImplemented(AIProviderID)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "No API key set for \(provider.displayName). Add one in Settings."
        case .invalidAPIKey:
            return "The API key was rejected. Check it in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Rate limited. Try again in \(retryAfter)s." }
            return "Rate limited. Try again shortly."
        case .networkTimeout:
            return "Network Error – the request timed out."
        case .network(let message):
            return "Network Error – \(message)"
        case .badRequest(let message):
            return "Request rejected: \(message)"
        case .serverError(let status):
            return "The AI service returned an error (HTTP \(status)). Try again later."
        case .invalidResponse:
            return "The AI service returned an unexpected response."
        case .notImplemented(let provider):
            return "\(provider.displayName) support is not implemented yet."
        }
    }
}

/// The single seam every LLM backend implements. Adding a new provider means
/// writing one conforming type and registering it in `AILayerCoordinator` – no
/// caller code changes (satisfies the "zero changes to the view model" criterion).
protocol AIProviderProtocol {
    var providerID: AIProviderID { get }

    /// Applies `mode`'s system prompt to `text` and returns the processed result.
    func process(text: String, mode: ProcessingMode) async throws -> String
}
