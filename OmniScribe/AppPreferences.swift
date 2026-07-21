import Foundation
import Combine

/// Shared, observable app preferences bound by the Settings UI and read by the
/// dictation pipeline. Holds only non-secret choices — the active mode and the
/// selected provider. **API keys are never stored here**; they live exclusively
/// in `KeychainManager`.
final class AppPreferences: ObservableObject {

    static let shared = AppPreferences()

    private let defaults: UserDefaults
    private let modeKey = "OmniScribe.selectedMode"

    /// The processing mode applied after transcription. Persisted so it survives
    /// relaunch. `didSet` writes through to `UserDefaults`.
    @Published var selectedMode: ProcessingMode {
        didSet { defaults.set(selectedMode.rawValue, forKey: modeKey) }
    }

    /// The active AI provider. Bridged to `AILayerCoordinator`, which is the
    /// source of truth for the persisted value (keeps a single writer).
    @Published var selectedProvider: AIProviderID {
        didSet { AILayerCoordinator.shared.selectedProvider = selectedProvider }
    }

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: modeKey),
           let mode = ProcessingMode(rawValue: raw) {
            selectedMode = mode
        } else {
            selectedMode = .ltTyping
        }

        selectedProvider = AILayerCoordinator.shared.selectedProvider
    }
}
