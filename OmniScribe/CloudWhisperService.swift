import Foundation

/// Errors from the OpenAI Whisper transcription path.
enum CloudTranscriptionError: LocalizedError {
    case missingAPIKey
    case emptyAudio
    case invalidAPIKey
    case rateLimited(retryAfter: Int?)
    case networkTimeout
    case network(String)
    case badRequest(String)
    case serverError(status: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No OpenAI API key set. Add it in Settings → API Keys → GPT (OpenAI)."
        case .emptyAudio:
            return "No speech was captured."
        case .invalidAPIKey:
            return "The OpenAI API key was rejected. Check it in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "OpenAI rate limited. Try again in \(retryAfter)s." }
            return "OpenAI rate limited. Try again shortly."
        case .networkTimeout:
            return "Network Error – the transcription request timed out."
        case .network(let message):
            return "Network Error – \(message)"
        case .badRequest(let message):
            return "Transcription request rejected: \(message)"
        case .serverError(let status):
            return "OpenAI returned an error (HTTP \(status)). Try again later."
        case .invalidResponse:
            return "OpenAI returned an unexpected response."
        }
    }
}

/// Cloud speech-to-text via OpenAI's Whisper transcription API
/// (`POST /v1/audio/transcriptions`). Chosen for languages Apple's on-device
/// Speech framework does not support (e.g. Lithuanian) and for Intel Macs, where
/// cloud inference is faster than local models.
///
/// Same public surface as `LocalTranscriptionService` (an `actor` with
/// `preloadModel()` + `transcribe(samples:)`) so the pipeline is unchanged.
actor CloudWhisperService {

    /// Transcription model. `whisper-1` is broadly available and multilingual.
    private let model: String
    /// ISO-639-1 language hint (e.g. "lt"). Improves accuracy and speed.
    private let language: String

    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let session: URLSession

    init(model: String = "whisper-1", language: String = "lt") {
        self.model = model
        self.language = language

        let config = URLSessionConfiguration.default
        // Audio upload + transcription can take a few seconds; allow generous time.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: – Launch

    /// Nothing to preload for a cloud service; just report whether a key is set.
    func preloadModel() async {
        let hasKey = KeychainManager.shared.hasAPIKey(for: .openai)
        print("[CloudWhisperService] Ready. OpenAI key present: \(hasKey).")
    }

    // MARK: – Transcription

    func transcribe(samples: [Float]) async throws -> STTResult {
        guard !samples.isEmpty else { throw CloudTranscriptionError.emptyAudio }

        guard let apiKey = try KeychainManager.shared.apiKey(for: .openai), !apiKey.isEmpty else {
            throw CloudTranscriptionError.missingAPIKey
        }

        let wav = Self.makeWavData(samples: samples, sampleRate: 16_000)
        let request = makeRequest(apiKey: apiKey, wav: wav)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw CloudTranscriptionError.networkTimeout
        } catch let urlError as URLError {
            throw CloudTranscriptionError.network(urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.invalidResponse
        }
        try Self.validate(status: http.statusCode, data: data, headers: http)

        let text = try Self.parseText(from: data)
        let duration = TimeInterval(samples.count) / 16_000.0
        return STTResult(text: text, language: language, audioDuration: duration, source: .cloud)
    }

    // MARK: – Request building

    private func makeRequest(apiKey: String, wav: Data) -> URLRequest {
        let boundary = "OmniScribeBoundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        // Audio file part.
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.appendString("\r\n")

        field("model", model)
        field("language", language)
        field("response_format", "json")

        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    // MARK: – Response handling

    private static func validate(status: Int, data: Data, headers: HTTPURLResponse) throws {
        switch status {
        case 200:
            return
        case 401:
            throw CloudTranscriptionError.invalidAPIKey
        case 429:
            let retryAfter = headers.value(forHTTPHeaderField: "retry-after").flatMap { Int($0) }
            throw CloudTranscriptionError.rateLimited(retryAfter: retryAfter)
        case 400:
            throw CloudTranscriptionError.badRequest(decodeErrorMessage(from: data) ?? "invalid request")
        case 500...599:
            throw CloudTranscriptionError.serverError(status: status)
        default:
            throw CloudTranscriptionError.badRequest(decodeErrorMessage(from: data) ?? "HTTP \(status)")
        }
    }

    private static func parseText(from data: Data) throws -> String {
        guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw CloudTranscriptionError.invalidResponse
        }
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data))?.error.message
    }

    // MARK: – WAV encoding (16 kHz mono, 16-bit PCM)

    /// Builds a minimal RIFF/WAVE file in memory from Float samples.
    private static func makeWavData(samples: [Float], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data()
        data.appendString("RIFF")
        data.appendUInt32LE(UInt32(36 + dataSize))
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendUInt32LE(16)                       // PCM fmt chunk size
        data.appendUInt16LE(1)                        // audioFormat = PCM
        data.appendUInt16LE(UInt16(channels))
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(UInt16(blockAlign))
        data.appendUInt16LE(UInt16(bitsPerSample))
        data.appendString("data")
        data.appendUInt32LE(UInt32(dataSize))

        data.reserveCapacity(data.count + dataSize)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let value = Int16(clamped * Float(Int16.max))
            data.appendUInt16LE(UInt16(bitPattern: value))
        }
        return data
    }
}

// MARK: – JSON models

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct OpenAIErrorResponse: Decodable {
    let error: Detail
    struct Detail: Decodable {
        let message: String
        let type: String?
    }
}

// MARK: – Data helpers

private extension Data {
    mutating func appendString(_ string: String) {
        if let d = string.data(using: .utf8) { append(d) }
    }
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendUInt16LE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
