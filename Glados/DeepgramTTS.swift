import Foundation
import NaturalLanguage

// MARK: - TextChunker

enum TextChunker {
    static let maxChunkLength = 500

    static func chunk(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let sentence = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            return true
        }

        var chunks: [String] = []
        var current = ""

        for sentence in sentences {
            if sentence.count > maxChunkLength {
                // Flush current
                if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                // Split long sentence at word boundaries
                chunks.append(contentsOf: splitLong(sentence))
            } else if current.count + sentence.count + 1 > maxChunkLength {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = sentence
            } else {
                current = current.isEmpty ? sentence : current + " " + sentence
            }
        }
        if !current.isEmpty { chunks.append(current.trimmingCharacters(in: .whitespaces)) }
        return chunks.filter { !$0.isEmpty }
    }

    private static func splitLong(_ text: String) -> [String] {
        var result: [String] = []
        let words = text.components(separatedBy: " ")
        var current = ""
        for word in words {
            if current.count + word.count + 1 > maxChunkLength {
                if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
                current = word
            } else {
                current = current.isEmpty ? word : current + " " + word
            }
        }
        if !current.isEmpty { result.append(current.trimmingCharacters(in: .whitespaces)) }
        return result
    }
}

// MARK: - DeepgramTTS

actor DeepgramTTS {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Streams PCM audio data chunks for the given text.
    func stream(text: String, voice: String = "aura-asteria-en") async throws -> AsyncThrowingStream<Data, Error> {
        guard let apiKey = Keychain.get("deepgramAPIKey"), !apiKey.isEmpty else {
            throw TTSError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.deepgram.com/v1/speak?model=\(voice)&encoding=linear16&sample_rate=24000")!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

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
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum TTSError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "No API key set. Tap the key icon to add one."
        case .invalidResponse: return "Invalid response from TTS service."
        case .httpError(let code): return "TTS service returned HTTP \(code). Check your API key."
        }
    }
}

// Legacy alias so existing catch sites keep compiling
typealias DeepgramError = TTSError
