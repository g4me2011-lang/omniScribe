import Foundation

/// Detects when the user has stopped talking so recording can auto-stop.
///
/// Design notes:
/// - Operates on the **already-converted** 16 kHz mono stream, so silence is
///   measured in *samples*, not wall-clock time. This makes the detector fully
///   deterministic and independent of buffer scheduling jitter.
/// - Requires speech to have started at least once (`hasDetectedSpeech`) before
///   it will ever fire. Otherwise the very first silent buffers would stop a
///   recording before the user had a chance to speak.
/// - `onSilenceTimeout` fires exactly **once** per session; call `reset()` to arm
///   it again for the next recording.
final class VoiceActivityDetector {

    // MARK: – Tuning

    /// RMS amplitude below which a buffer is considered "silence".
    /// 0.012 works well for a normal desk mic; expose later via Settings.
    private let silenceThreshold: Float

    /// How many continuous seconds of silence trigger the timeout.
    private let silenceDuration: TimeInterval

    /// Sample rate of the incoming (converted) stream. Whisper mandates 16 kHz.
    private let sampleRate: Double

    /// Precomputed silence budget in samples (`silenceDuration * sampleRate`).
    private let silenceSampleBudget: Int

    // MARK: – State

    private var hasDetectedSpeech = false
    private var consecutiveSilentSamples = 0
    private var hasFired = false

    /// Called on the audio thread the first time `silenceDuration` of continuous
    /// silence is observed after speech. Hop to the main queue inside the closure.
    var onSilenceTimeout: (() -> Void)?

    // MARK: – Init

    init(sampleRate: Double = 16_000,
         silenceThreshold: Float = 0.012,
         silenceDuration: TimeInterval = 2.0) {
        self.sampleRate         = sampleRate
        self.silenceThreshold   = silenceThreshold
        self.silenceDuration    = silenceDuration
        self.silenceSampleBudget = Int(silenceDuration * sampleRate)
    }

    // MARK: – Public API

    /// Arms the detector for a fresh recording. Call this in `start()`.
    func reset() {
        hasDetectedSpeech = false
        consecutiveSilentSamples = 0
        hasFired = false
    }

    /// Feed each converted buffer here. Cheap: one RMS pass over the samples.
    func process(samples: [Float]) {
        guard !hasFired, !samples.isEmpty else { return }

        let rms = Self.rootMeanSquare(samples)

        if rms >= silenceThreshold {
            // Voice present – note it and clear any accumulated silence.
            hasDetectedSpeech = true
            consecutiveSilentSamples = 0
            return
        }

        // Silence only counts once the user has actually started speaking.
        guard hasDetectedSpeech else { return }

        consecutiveSilentSamples += samples.count
        if consecutiveSilentSamples >= silenceSampleBudget {
            hasFired = true
            onSilenceTimeout?()
        }
    }

    // MARK: – Helpers

    private static func rootMeanSquare(_ samples: [Float]) -> Float {
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }
}
