import Foundation

/// The outcome of a single speech-to-text pass.
///
/// Deliberately provider-agnostic: both `LocalTranscriptionService` (WhisperKit)
/// and the future `CloudWhisperService` return this same value so the rest of the
/// pipeline never needs to know where the text came from.
struct STTResult: Equatable {

    /// The transcribed, whitespace-trimmed text. May be empty for silent input.
    let text: String

    /// BCP-47 / Whisper language code if the model reported one (e.g. `"lt"`, `"en"`).
    let language: String?

    /// Wall-clock seconds the audio spanned (not the time spent transcribing).
    let audioDuration: TimeInterval

    /// Which backend produced this result – useful for logging and the HUD.
    let source: Source

    enum Source: String {
        case local  = "Apple Speech (on-device)"
        case cloud  = "Apple Speech (server)"
    }

    /// `true` when the model returned no usable words.
    var isEmpty: Bool { text.isEmpty }

    static let empty = STTResult(text: "", language: nil, audioDuration: 0, source: .local)
}
