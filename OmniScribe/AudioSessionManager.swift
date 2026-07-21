import AVFoundation

/// Errors surfaced by the audio pipeline. All are catchable – a dropped mic
/// must never crash the app.
enum AudioEngineError: LocalizedError {
    case noInputAvailable
    case converterCreationFailed
    case engineStartFailed(underlying: Error)
    case interruptedByDeviceChange

    var errorDescription: String? {
        switch self {
        case .noInputAvailable:
            return "No microphone input is available."
        case .converterCreationFailed:
            return "Could not create the 16 kHz audio converter."
        case .engineStartFailed(let underlying):
            return "The audio engine failed to start: \(underlying.localizedDescription)"
        case .interruptedByDeviceChange:
            return "Recording was interrupted because the audio device changed."
        }
    }
}

/// Captures microphone audio with `AVAudioEngine`, converts it to the 16 kHz mono
/// Float32 stream Whisper requires, and streams it through a `VoiceActivityDetector`.
///
/// Threading contract:
/// - `start()` / `stop()` must be called on the main thread.
/// - The input tap runs on a real-time audio thread; the only shared state it
///   touches is `capturedSamples`, guarded by `bufferLock`.
///
/// macOS note: there is no `AVAudioSession` on macOS (that is iOS-only), so device
/// routing is handled entirely via the engine's input node plus the
/// `AVAudioEngineConfigurationChange` notification.
final class AudioSessionManager {

    // MARK: – Public callbacks (invoked on the main queue)

    /// Fired when the VAD sees `silenceDuration` of continuous silence after speech.
    /// The coordinator should respond by calling `stop()` and transcribing.
    var onSilenceDetected: (() -> Void)?

    /// Fired when recording has to abort (e.g. the active device vanished).
    var onError: ((AudioEngineError) -> Void)?

    // MARK: – Private

    private let engine = AVAudioEngine()
    private let vad = VoiceActivityDetector()

    /// Whisper's required target format: 16 kHz, mono, non-interleaved Float32.
    private let targetFormat: AVAudioFormat

    private var converter: AVAudioConverter?
    private var capturedSamples: [Float] = []
    private let bufferLock = NSLock()

    private(set) var isRecording = false

    // MARK: – Init

    init() {
        // Force-unwrap is safe: this exact format is always constructible.
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: 16_000,
                                     channels: 1,
                                     interleaved: false)!

        // React to headphones/AirPods being plugged in or the default device changing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        vad.onSilenceTimeout = { [weak self] in
            // Called on the audio thread – hop to main for UI-driving work.
            DispatchQueue.main.async { self?.onSilenceDetected?() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: – Recording lifecycle

    /// Begins capture. Resets buffers and the VAD, then installs the tap and
    /// starts the engine. Throws `AudioEngineError` on any failure.
    func start() throws {
        guard !isRecording else { return }

        resetBuffer()
        vad.reset()

        try installTapAndStart()
        isRecording = true
    }

    /// Stops capture and returns the full 16 kHz mono sample buffer.
    /// Always removes the tap **before** stopping the engine – doing it in the
    /// other order is the classic cause of `com.apple.coreaudio` crashes.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return snapshotSamples() }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        return snapshotSamples()
    }

    // MARK: – Engine setup

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // A sample rate of 0 means the OS reports no usable input device.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioEngineError.noInputAvailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioEngineError.converterCreationFailed
        }
        self.converter = converter

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.process(inputBuffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw AudioEngineError.engineStartFailed(underlying: error)
        }
    }

    // MARK: – Buffer processing (audio thread)

    private func process(inputBuffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Size the output buffer for the sample-rate change (e.g. 48k -> 16k).
        let ratio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              conversionError == nil,
              let channel = outputBuffer.floatChannelData?[0],
              outputBuffer.frameLength > 0 else { return }

        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: frameCount))

        appendSamples(samples)
        vad.process(samples: samples)
    }

    // MARK: – Device change handling

    /// Rebuilds the tap when the audio route changes mid-recording (AirPods, etc.)
    /// instead of letting the stale engine crash. If the rebuild fails, we abort
    /// cleanly and report a catchable error.
    @objc private func handleConfigurationChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRecording else { return }

            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()

            do {
                try self.installTapAndStart()
            } catch {
                self.isRecording = false
                let audioError = (error as? AudioEngineError) ?? .interruptedByDeviceChange
                self.onError?(audioError)
            }
        }
    }

    // MARK: – Thread-safe buffer access

    private func resetBuffer() {
        bufferLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        bufferLock.unlock()
    }

    private func appendSamples(_ samples: [Float]) {
        bufferLock.lock()
        capturedSamples.append(contentsOf: samples)
        bufferLock.unlock()
    }

    private func snapshotSamples() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return capturedSamples
    }
}
