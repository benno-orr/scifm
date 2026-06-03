import XCTest
@testable import sciFM

final class ArticleProcessorTests: XCTestCase {
    let processor = ArticleProcessor()

    func testGluedCitationStripping_realWords() async {
        let r1 = await processor.cleanText("shown1,2")
        XCTAssertEqual(r1, "shown")
        let r2 = await processor.cleanText("demonstrated3")
        XCTAssertEqual(r2, "demonstrated")
        let result = await processor.cleanText("results1–3")
        XCTAssertTrue(result.contains("results"))
        XCTAssertFalse(result.contains("1"))
    }

    func testGluedCitationStripping_geneNames() async {
        let r1 = await processor.cleanText("IL6")
        XCTAssertEqual(r1, "IL6")
        let r2 = await processor.cleanText("p53")
        XCTAssertEqual(r2, "p53")
        let r3 = await processor.cleanText("H3K27me3")
        XCTAssertEqual(r3, "H3K27me3")
    }

    func testGluedCitationStripping_hyphenated() async {
        let r1 = await processor.cleanText("IL-6")
        XCTAssertEqual(r1, "IL-6")
        let r2 = await processor.cleanText("COVID-19")
        XCTAssertEqual(r2, "COVID-19")
    }

    func testReferencesTruncation() async {
        let input = "Some body text.\n\nReferences\n\nSmith et al. 2023..."
        let result = await processor.cleanText(input)
        XCTAssertFalse(result.contains("Smith et al."))
        XCTAssertTrue(result.contains("Some body text"))
    }

    func testFigureRefStripping() async {
        let result = await processor.cleanText("as shown (Fig. 1A) in the data")
        XCTAssertFalse(result.contains("Fig. 1A"))
        XCTAssertTrue(result.contains("as shown"))
        XCTAssertTrue(result.contains("in the data"))
    }

    func testAuthorYearStripping() async {
        let result = await processor.cleanText("previously described (Smith et al., 2023)")
        XCTAssertFalse(result.contains("Smith"))
        XCTAssertTrue(result.contains("previously described"))
    }

    func testBracketedCitationStripping() async {
        let result = await processor.cleanText("as previously shown [1,2,3]")
        XCTAssertFalse(result.contains("[1"))
        XCTAssertTrue(result.contains("as previously shown"))
    }

    func testUnicodeSuperscriptStripping() async {
        let result = await processor.cleanText("as noted¹² elsewhere")
        XCTAssertFalse(result.contains("¹"))
        XCTAssertTrue(result.contains("as noted"))
    }

    func testBlocklistWordsNotStripped() async {
        let result = await processor.cleanText("see Figure1 and Table2")
        XCTAssertTrue(result.contains("Figure1") || result.contains("Figure"))
    }
}
