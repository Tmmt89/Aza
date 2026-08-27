import XCTest

@MainActor
final class ChechenLexiconTests: XCTestCase {
    func testPalochkaCodepointsCanonicalize() {
        XCTAssertTrue(ChechenLexicon.shared.isAvailable)
        XCTAssertTrue(ChechenLexicon.shared.contains("ӀАЛАМ"))
        XCTAssertEqual(LayoutCorrectionEngine.canonicalPalochkaForm(of: "Г1АЛА"), "гӏала")
        XCTAssertEqual(LayoutCorrectionEngine.canonicalPalochkaForm(of: "гІала"), "гӏала")
        XCTAssertEqual(ChechenLexicon.shared.canonicalTwins(in: "гiала"), "гiала")
        XCTAssertEqual(ChechenLexicon.shared.canonicalTwins(in: "гІала"), "гӏала")
    }

    func testFrequencyGatesAndOneEditNeighbor() {
        XCTAssertEqual(ChechenLexicon.shared.frequency(of: "ду"), 20_114)
        XCTAssertTrue(ChechenLexicon.shared.isFrequent("ларам"))
        XCTAssertFalse(ChechenLexicon.shared.isFrequent("несуществующее"))
        XCTAssertEqual(ChechenLexicon.shared.oneEditNeighbor(of: "барклла"), "баркалла")
    }
}
