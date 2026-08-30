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
        // Прибитая частота — контракт с конкретным артефактом словаря;
        // при пересборке обновляется на фактическую (сборка 30.08: 71 263
        // слова, покрытие 98,1%, maxShare 0.45/0.30).
        XCTAssertEqual(ChechenLexicon.shared.frequency(of: "ду"), 32_271)
        XCTAssertTrue(ChechenLexicon.shared.isFrequent("ларам"))
        XCTAssertFalse(ChechenLexicon.shared.isFrequent("несуществующее"))
        XCTAssertEqual(ChechenLexicon.shared.oneEditNeighbor(of: "барклла"), "баркалла")
    }
}
