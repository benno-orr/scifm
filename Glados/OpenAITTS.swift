import Foundation

actor OpenAITTS {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Streams raw PCM audio (signed 16-bit, 24 kHz, mono) — same format as DeepgramTTS.
    func stream(text: String, voice: String = "nova") async throws -> AsyncThrowingStream<Data, Error> {
        guard let apiKey = Keychain.get("openaiAPIKey"), !apiKey.isEmpty else {
            throw TTSError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "response_format": "pcm",
        ])

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw TTSError.httpError(httpResponse.statusCode)
        }

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var buffer = Data()
                    for try await byte in asyncBytes {
                        buffer.append(byte)
                        if buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer = Data()
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
