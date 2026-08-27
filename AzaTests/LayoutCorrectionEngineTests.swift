import XCTest

@MainActor
final class LayoutCorrectionEngineTests: XCTestCase {
    private let enToRu = Dictionary(uniqueKeysWithValues: zip(
        Array("qwertyuiop[]asdfghjkl;'zxcvbnm,."),
        Array("йцукенгшщзхъфывапролджэячсмитьбю")
    ))

    override func setUp() {
        super.setUp()
        UserWordLists.shared.suspendedForTests = true
    }

    override func tearDown() {
        UserWordLists.shared.suspendedForTests = false
        super.tearDown()
    }

    func testFixedRuEnglishAndChechenRemaps() {
        XCTAssertEqual(LayoutCorrectionEngine.remapped("ghbdtn", table: enToRu), "привет")
        XCTAssertEqual(LayoutCorrectionEngine.remapped("[mj", table: enToRu), "хьо")
        XCTAssertEqual(LayoutCorrectionEngine.remapped("wbuf[m", table: enToRu), "цигахь")

        let ruToEn = Dictionary(uniqueKeysWithValues: enToRu.map { ($0.value, $0.key) })
        XCTAssertEqual(LayoutCorrectionEngine.remapped("руддщ", table: ruToEn), "hello")
        XCTAssertNil(LayoutCorrectionEngine.remapped("hello!", table: enToRu))
    }

    func testPalochkaHypothesisAndAmbiguityAbstention() {
        XCTAssertEqual(LayoutCorrectionEngine.normalizedPalochka("1алам"), "ӏалам")
        XCTAssertTrue(LayoutCorrectionEngine.firstKeyAlternativeIsChechen(
            for: "vfkj", table: enToRu
        ))
        XCTAssertFalse(LayoutCorrectionEngine.firstKeyAlternativeIsChechen(
            for: "ghbdtn", table: enToRu
        ))
    }

    func testTypoStageIsGatedBySetting() {
        let saved = UserDefaults.standard.object(forKey: ChechenAutocorrect.typoStorageKey)
        defer { UserDefaults.standard.set(saved, forKey: ChechenAutocorrect.typoStorageKey) }

        ChechenAutocorrect.isTypoCorrectionEnabled = false
        XCTAssertNil(LayoutCorrectionEngine.typoCorrection(
            for: "барклла", isValidRussian: { _ in false }
        ))
        ChechenAutocorrect.isTypoCorrectionEnabled = true
        XCTAssertEqual(LayoutCorrectionEngine.typoCorrection(
            for: "барклла", isValidRussian: { _ in false }
        ), "баркалла")
    }

    func testForwardAndBackwardPhraseContext() {
        let remap: (String) -> String? = { word in
            LayoutCorrectionEngine.chechenContextRemap(
                for: word, table: self.enToRu, isValidEnglish: { _ in false }
            )
        }
        XCTAssertEqual(LayoutCorrectionEngine.forwardContextRemap(
            for: "le", previousIsChechen: true, remap: remap
        ), "ду")
        XCTAssertNil(LayoutCorrectionEngine.forwardContextRemap(
            for: "le", previousIsChechen: false, remap: remap
        ))

        let span = LayoutCorrectionEngine.backwardContextSpan(previous: [
            .init(typed: "le", delimiter: " ", chechen: false, corrected: false),
            .init(typed: "cj", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "цигахь", remap: remap)
        XCTAssertEqual(span, .init(original: "le cj ", corrected: "ду со ",
                                   originalWords: ["le", "cj"]))

        XCTAssertNil(LayoutCorrectionEngine.backwardContextSpan(previous: [
            .init(typed: "le", delimiter: " ", chechen: false, corrected: false),
            .init(typed: "in", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "цигахь", remap: remap))
    }

    func testExcludedAppPolicyAndTextHelpers() {
        XCTAssertTrue(ExcludedApps.isCorrectionDenied(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(ExcludedApps.isCorrectionDenied(bundleID: "com.jetbrains.intellij"))
        XCTAssertTrue(ExcludedApps.isCorrectionDenied(bundleID: "com.1password.1password"))
        XCTAssertFalse(ExcludedApps.isCorrectionDenied(bundleID: "com.apple.TextEdit"))
        XCTAssertEqual(TextInsertion.matchingCase(of: "Ghbdtn ", applyingTo: "привет "),
                       "Привет ")
        XCTAssertEqual(TextInsertion.trailingToken(of: "дика лор"), "лор")
        XCTAssertEqual(TextInsertion.trailingToken(of: "дика "), "")
    }
}
