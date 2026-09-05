import XCTest

@MainActor
final class LayoutCorrectionEngineTests: XCTestCase {
    private let enToRu = Dictionary(uniqueKeysWithValues: zip(
        Array("qwertyuiop[]asdfghjkl;'zxcvbnm,."),
        Array("йцукенгшщзхъфывапролджэячсмитьбю")
    ))

    private var savedLayoutFlag: Any?
    private var savedLatinFlag: Any?

    override func setUp() {
        super.setUp()
        UserWordLists.shared.suspendedForTests = true
        // Тесты движка работают при включённой коррекции; по умолчанию она
        // теперь выключена, поэтому включаем явно и восстанавливаем после.
        savedLayoutFlag = UserDefaults.standard.object(forKey: ChechenAutocorrect.layoutStorageKey)
        savedLatinFlag = UserDefaults.standard.object(forKey: ChechenAutocorrect.latinizationStorageKey)
        ChechenAutocorrect.isLayoutCorrectionEnabled = true
        ChechenAutocorrect.isLatinizationEnabled = true
    }

    override func tearDown() {
        UserWordLists.shared.suspendedForTests = false
        UserDefaults.standard.set(savedLayoutFlag, forKey: ChechenAutocorrect.layoutStorageKey)
        UserDefaults.standard.set(savedLatinFlag, forKey: ChechenAutocorrect.latinizationStorageKey)
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

    func testShortWordRemaps() {
        XCTAssertEqual(LayoutCorrectionEngine.correction(for: "ghbdtn!")?.text, "привет!")
        XCTAssertEqual(LayoutCorrectionEngine.correction(for: "ghbdtn?!")?.text, "привет?!")
        // Двухбуквенные местоимения и частицы исправляются, однобуквенное —
        // только «я»; английские и кодовые диграфы не трогаются.
        XCTAssertEqual(LayoutCorrectionEngine.correction(for: "ns")?.text, "ты")
        XCTAssertEqual(LayoutCorrectionEngine.correction(for: "yt")?.text, "не")
        XCTAssertEqual(LayoutCorrectionEngine.correction(for: "z")?.text, "я")
        XCTAssertNil(LayoutCorrectionEngine.correction(for: "in"))
        XCTAssertNil(LayoutCorrectionEngine.correction(for: "if"))
        XCTAssertNil(LayoutCorrectionEngine.correction(for: "js"))
        XCTAssertNil(LayoutCorrectionEngine.correction(for: "b"))
        XCTAssertNil(LayoutCorrectionEngine.correction(for: "t"))
    }

    func testPunctuationCannotBypassUserExclusion() {
        XCTAssertNil(LayoutCorrectionEngine.correction(
            for: "ghbdtn!", isNeverCorrect: { $0 == "ghbdtn!" }))
        XCTAssertNil(LayoutCorrectionEngine.correction(
            for: "ghbdtn!", isNeverCorrect: { $0 == "ghbdtn" }))
        XCTAssertEqual(LayoutCorrectionEngine.correction(
            for: "ghbdtn?", isNeverCorrect: { $0 == "ghbdtn!" })?.text, "привет?")
    }

    func testRussianBackwardSpan() {
        // «e vtyz» → «у меня»: однобуквенное «у» подтягивается ретроактивно.
        let span = LayoutCorrectionEngine.backwardRussianSpan(previous: [
            .init(typed: "e", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "меня")
        XCTAssertEqual(span, .init(original: "e ", corrected: "у ",
                                   originalWords: ["e"]))
        // Валидное английское слово обрывает расширение.
        XCTAssertNil(LayoutCorrectionEngine.backwardRussianSpan(previous: [
            .init(typed: "in", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "меня"))
        // Однобуквенное, не являющееся русским словом (t→е), не подтягивается.
        XCTAssertNil(LayoutCorrectionEngine.backwardRussianSpan(previous: [
            .init(typed: "t", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "меня"))
    }

    func testRussianContextRemapRespectsAmbiguityAbstention() {
        // Фикс аудита 29.08: бэквард-контекст не имеет права ретроактивно
        // обойти воздержание прямого пути («vfkj» может быть чеченским
        // «хало»). Обычное русское слово при этом ремапится.
        let saved = UserDefaults.standard.object(
            forKey: ChechenAutocorrect.ambiguityStorageKey)
        defer { UserDefaults.standard.set(saved, forKey: ChechenAutocorrect.ambiguityStorageKey) }
        ChechenAutocorrect.isAmbiguityAbstentionEnabled = true
        XCTAssertNil(LayoutCorrectionEngine.russianContextRemap(for: "vfkj"))
        XCTAssertEqual(LayoutCorrectionEngine.russianContextRemap(for: "ghbdtn"), "привет")
    }

    func testOneEditMatchGuardsLatinization() {
        // «мало» в одной правке от частотного чеченского «хало» — улика
        // неоднозначности; короче четырёх букв предохранитель молчит.
        XCTAssertTrue(ChechenLexicon.shared.hasOneEditMatch(of: "мало"))
        XCTAssertFalse(ChechenLexicon.shared.hasOneEditMatch(of: "код"))
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

    func testLayoutAndTyposCanBeEnabledIndependently() {
        let saved = UserDefaults.standard.object(forKey: ChechenAutocorrect.typoStorageKey)
        defer { UserDefaults.standard.set(saved, forKey: ChechenAutocorrect.typoStorageKey) }

        for layout in [false, true] {
            for typos in [false, true] {
                ChechenAutocorrect.isLayoutCorrectionEnabled = layout
                ChechenAutocorrect.isTypoCorrectionEnabled = typos
                XCTAssertEqual(LayoutCorrectionEngine.correction(for: "ghbdtn")?.text,
                               layout ? "привет" : nil)
                let correction = LayoutCorrectionEngine.correction(for: "барклла!")
                XCTAssertEqual(correction?.text, typos ? "баркалла!" : nil)
                XCTAssertNil(correction?.inputLanguage)
            }
        }

        ChechenAutocorrect.isLayoutCorrectionEnabled = false
        ChechenAutocorrect.isTypoCorrectionEnabled = true
        XCTAssertNil(LayoutCorrectionEngine.correction(
            for: "барклла!", isNeverCorrect: { $0 == "барклла" }))
        XCTAssertNil(LayoutCorrectionEngine.correction(for: "1алам"))
        XCTAssertNil(LayoutCorrectionEngine.forwardContextRemap(
            for: "le", previousIsChechen: true))
        XCTAssertNil(LayoutCorrectionEngine.backwardContextSpan(previous: [
            .init(typed: "le", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "баркалла"))
        XCTAssertNil(LayoutCorrectionEngine.backwardRussianSpan(previous: [
            .init(typed: "e", delimiter: " ", chechen: false, corrected: false),
        ], correctedWord: "меня"))
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
        XCTAssertFalse(ExcludedApps.isCorrectionDenied(bundleID: "com.apple.Terminal"))
        XCTAssertFalse(ExcludedApps.isCorrectionDenied(bundleID: "com.jetbrains.intellij"))
        XCTAssertTrue(ExcludedApps.isCorrectionDenied(bundleID: "com.1password.1password"))
        XCTAssertFalse(ExcludedApps.isCorrectionDenied(bundleID: "com.apple.TextEdit"))
        XCTAssertEqual(TextInsertion.matchingCase(of: "Ghbdtn ", applyingTo: "привет "),
                       "Привет ")
        XCTAssertEqual(TextInsertion.trailingToken(of: "дика лор"), "лор")
        XCTAssertEqual(TextInsertion.trailingToken(of: "дика "), "")
    }
}
