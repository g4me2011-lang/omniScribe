import Foundation

/// Routes a transcription to whichever provider the user has selected, so the
/// rest of the app depends only on this one entry point. Swapping providers is a
/// dictionary lookup here — callers never change (satisfies the strategy-pattern
/// "zero changes to the calling view model" criterion).
final class AILayerCoordinator {

    static let shared = AILayerCoordinator()

    /// Registered backends, keyed by provider. Add a new provider by registering
    /// one conforming instance — nothing else in the app changes.
    private let providers: [AIProviderID: AIProviderProtocol]

    private let selectedProviderKey = "OmniScribe.selectedProvider"
    private let defaults: UserDefaults

    init(providers: [AIProviderProtocol] = [ClaudeService()],
         defaults: UserDefaults = .standard) {
        self.providers = Dictionary(uniqueKeysWithValues: providers.map { ($0.providerID, $0) })
        self.defaults = defaults
    }

    // MARK: – Provider selection

    /// The active provider. Persisted as a plain preference (the *choice* is not a
    /// secret — only the API key is, and that lives in the Keychain). Defaults to
    /// Claude when unset or set to a provider that isn't registered.
    var selectedProvider: AIProviderID {
        get {
            guard let raw = defaults.string(forKey: selectedProviderKey),
                  let provider = AIProviderID(rawValue: raw),
                  providers[provider] != nil
            else { return .claude }
            return provider
        }
        set { defaults.set(newValue.rawValue, forKey: selectedProviderKey) }
    }

    // MARK: – Processing

    /// Sends `text` through the selected provider using `mode`'s system prompt.
    func process(text: String, mode: ProcessingMode) async throws -> String {
        let provider = selectedProvider
        guard let service = providers[provider] else {
            throw AIError.notImplemented(provider)
        }
        return try await service.process(text: text, mode: mode)
    }
}
