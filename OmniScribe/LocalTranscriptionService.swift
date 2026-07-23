import Foundation
import Speech
import AVFoundation

/// Errors from the on-device speech-to-text path.
enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable(localeIdentifier: String)
    case emptyAudio
    case audioWriteFailed(String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech Recognition access is required. Enable it in System Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable(let localeIdentifier):
            return "Speech recognition is unavailable for language \"\(localeIdentifier)\". Try switching your system language, or check your connection."
        case .emptyAudio:
            return "No speech was captured."
        case .audioWriteFailed(let detail):
            return "Could not prepare the audio for recognition: \(detail)."
        case .recognitionFailed(let message):
            return "Transcription failed: \(message)"
        }
    }
}

/// On-device / offline speech-to-text via Apple's `Speech` framework
/// (`SFSpeechRecognizer`). Chosen over a bundled ML model for reliability: it is
/// part of macOS, needs no model download, and — where the language supports it —
/// runs fully on-device for privacy.
///
/// Kept as an `actor` with the same public surface as before so the rest of the
/// pipeline (`AppDelegate`) is unchanged: `preloadModel()` at launch,
/// `transcribe(samples:)` per dictation.
actor LocalTranscriptionService {

    /// Recognition language. Defaults to Lithuanian — the system locale (e.g.
    /// `en_LT`) reflects UI language, not spoken language, so relying on it made
    /// an English recognizer transcribe Lithuanian speech into an empty string.
    /// A later Settings picker can override this.
    private let locale: Locale

    private(set) var isModelLoaded = false

    init(locale: Locale = Locale(identifier: "lt-LT")) {
        self.locale = locale
    }

    // MARK: – Launch-time setup

    /// Requests Speech Recognition authorization so the system prompt appears at
    /// launch (not mid-dictation). Never throws; failure just means `transcribe`
    /// will report a clear error later.
    func preloadModel() async {
        let status = await Self.requestAuthorization()
        isModelLoaded = (status == .authorized)

        switch status {
        case .authorized:
            let onDevice = SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
            print("[LocalTranscriptionService] ✅ Speech authorized (locale \(locale.identifier), on-device: \(onDevice)).")
        default:
            print("[LocalTranscriptionService] ⚠️ Speech not authorized (status \(status.rawValue)).")
        }
    }

    // MARK: – Transcription

    /// Transcribes a 16 kHz mono Float32 buffer. Runs off the main thread by
    /// virtue of the actor. Throws a catchable `TranscriptionError` on any failure.
    func transcribe(samples: [Float]) async throws -> STTResult {
        guard !samples.isEmpty else { throw TranscriptionError.emptyAudio }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriptionError.notAuthorized
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable(localeIdentifier: locale.identifier)
        }

        // SFSpeechRecognizer works from an audio file; write the captured samples
        // to a temporary 16 kHz mono WAV, transcribe, then clean up.
        let url = try Self.writeWav(samples: samples, sampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        // Prefer fully on-device recognition when the language supports it (privacy);
        // otherwise fall back to Apple's server recognition (needs network).
        let onDevice = recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        let text = try await Self.recognize(recognizer: recognizer, request: request)
        let duration = TimeInterval(samples.count) / 16_000.0

        return STTResult(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                         language: locale.identifier,
                         audioDuration: duration,
                         source: onDevice ? .local : .cloud)
    }

    // MARK: – Helpers

    private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    /// Runs one recognition task and returns the final transcript string.
    private static func recognize(recognizer: SFSpeechRecognizer,
                                  request: SFSpeechRecognitionRequest) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: TranscriptionError.recognitionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let result, result.isFinal else { return }
                if !didResume {
                    didResume = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    /// Writes Float samples to a temporary mono WAV file for `SFSpeechURLRecognitionRequest`.
    private static func writeWav(samples: [Float], sampleRate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omniscribe-\(UUID().uuidString).wav")

        // File is written as 16-bit integer PCM (the format SFSpeech reads most
        // reliably); the in-memory buffer stays Float32 and AVAudioFile converts
        // on write.
        let settings: [String: Any] = [
            AVFormatIDKey:            kAudioFormatLinearPCM,
            AVSampleRateKey:          sampleRate,
            AVNumberOfChannelsKey:    1,
            AVLinearPCMBitDepthKey:   16,
            AVLinearPCMIsFloatKey:    false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        } catch {
            throw TranscriptionError.audioWriteFailed(error.localizedDescription)
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw TranscriptionError.audioWriteFailed("buffer allocation")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress {
                    channel[0].update(from: base, count: samples.count)
                }
            }
        }

        do {
            try file.write(from: buffer)
        } catch {
            throw TranscriptionError.audioWriteFailed(error.localizedDescription)
        }
        return url
    }
}
