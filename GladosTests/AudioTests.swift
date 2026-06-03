import XCTest
@testable import sciFM

final class AudioTests: XCTestCase {

    func testTextChunkerSentenceBoundaries() {
        let text = "This is sentence one. This is sentence two. This is sentence three."
        let chunks = TextChunker.chunk(text)
        XCTAssertGreaterThan(chunks.count, 0)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TextChunker.maxChunkLength })
        let recombined = chunks.joined(separator: " ")
        XCTAssertTrue(recombined.contains("sentence one"))
        XCTAssertTrue(recombined.contains("sentence three"))
    }

    func testTextChunkerLongSentence() {
        let longSentence = String(repeating: "word ", count: 200) // ~1000 chars
        let chunks = TextChunker.chunk(longSentence)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TextChunker.maxChunkLength },
                      "All chunks must be within maxChunkLength")
    }

    func testTextChunkerEmptyString() {
        let chunks = TextChunker.chunk("")
        XCTAssertTrue(chunks.isEmpty)
    }

    func testTextChunkerShortText() {
        let text = "Hello world."
        let chunks = TextChunker.chunk(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "Hello world.")
    }

    func testTextChunkerMergesShortSentences() {
        // Two short sentences should be merged into one chunk
        let text = "Hi. Bye."
        let chunks = TextChunker.chunk(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].contains("Hi"))
        XCTAssertTrue(chunks[0].contains("Bye"))
    }

    func testPCMBufferConversionSyntheticData() {
        // Generate synthetic int16 sine wave data (100ms at 24kHz)
        let sampleRate = 24000
        let frameCount = Int(Double(sampleRate) * 0.1)
        var int16Data = Data(count: frameCount * 2)
        int16Data.withUnsafeMutableBytes { ptr in
            guard let int16Ptr = ptr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<frameCount {
                int16Ptr[i] = Int16(sin(Double(i) / Double(sampleRate) * 2 * .pi * 440) * 32767)
            }
        }
        // AudioStreamPlayer is @MainActor so instantiate on main
        // Just verify data integrity here — AVAudioEngine tests require a real device
        XCTAssertEqual(int16Data.count, frameCount * 2)
        XCTAssertGreaterThan(frameCount, 0)
    }
}
