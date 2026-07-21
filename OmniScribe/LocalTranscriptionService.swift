import Foundation

#if canImport(WhisperKit)
import WhisperKit
#endif

/// Errors from the local speech-to-text path.
enum TranscriptionError: LocalizedError {
    case whisperKitNotLinked
    case modelNotReady
    case emptyAudio
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .whisperKitNotLinked:
            return "WhisperKit is not linked. Add the Swift package to enable on-device transcription."
        case .modelNotReady:
            return "The local Whisper model is still loading. Try again in a moment."
        case .emptyAudio:
            return "No speech was captured."
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

/// On-device speech-to-text via WhisperKit (CoreML, Apple-Silicon optimised).
///
/// Key decisions matching the spec:
/// - An `actor`, so model state is isolated and transcription can never block the
///   main thread – callers `await` from wherever they like.
/// - The model is loaded **once** via `preloadModel()` at app launch, not on the
///   hotkey press, to eliminate first-use latency.
/// - The WhisperKit dependency is wrapped in `#if canImport(WhisperKit)`. The
///   project therefore compiles and runs (audio + VAD fully working) **before**
///   the package is added; once you add it in Xcode the real path activates with
///   zero further code changes.
actor LocalTranscriptionService {

    /// Model name to load. "base" balances speed and accuracy; "small" is more
    /// accurate but heavier. Both are quantized CoreML variants on Apple Silicon.
    private let modelName: String

    private(set) var isModelLoaded = false

    #if canImport(WhisperKit)
    private var whisperKit: WhisperKit?
    #endif

    init(modelName: String = "base") {
        self.modelName = modelName
    }

    /// Downloads (first run) and loads the model into memory. Safe to call once
    /// at launch; subsequent calls are no-ops. Never throws – failure just leaves
    /// `isModelLoaded == false`, and `transcribe` reports a clear error later.
    func preloadModel() async {
        guard !isModelLoaded else { return }

        #if canImport(WhisperKit)
        do {
            let config = WhisperKitConfig(model: modelName)
            whisperKit = try await WhisperKit(config)
            isModelLoaded = true
            print("[LocalTranscriptionService] ✅ WhisperKit model '\(modelName)' loaded.")
        } catch {
            isModelLoaded = false
            print("[LocalTranscriptionService] ❌ Failed to load model: \(error.localizedDescription)")
        }
        #else
        print("[LocalTranscriptionService] ⚠️ WhisperKit not linked – add the SPM package to enable local STT.")
        #endif
    }

    /// Transcribes a 16 kHz mono Float32 buffer. Runs off the main thread by
    /// virtue of the actor. Throws a catchable `TranscriptionError` on any failure.
    func transcribe(samples: [Float]) async throws -> STTResult {
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }

        let duration = TimeInterval(samples.count) / 16_000.0

        #if canImport(WhisperKit)
        guard let whisperKit, isModelLoaded else { throw TranscriptionError.modelNotReady }

        do {
            let results = try await whisperKit.transcribe(audioArray: samples)
            let text = results
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return STTResult(text: text,
                             language: results.first?.language,
                             audioDuration: duration,
                             source: .local)
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
        #else
        throw TranscriptionError.whisperKitNotLinked
        #endif
    }
}
