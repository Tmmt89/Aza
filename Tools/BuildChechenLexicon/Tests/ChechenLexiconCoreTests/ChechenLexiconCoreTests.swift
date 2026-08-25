import XCTest
@testable import ChechenLexiconCore

final class ChechenLexiconCoreTests: XCTestCase {

    // MARK: Токенизация

    func testDigitInsideCyrillicWordStaysInWord() {
        XCTAssertEqual(Tokenizer().tokens(in: "г1ала ду цхьаъ"),
                       ["г1ала", "ду", "цхьаъ"])
    }

    func testDigitsAndTimeDoNotFormWords() {
        // Цифры и время не склеиваются в слова и не порождают токенов с кириллицей.
        XCTAssertEqual(Tokenizer().tokens(in: "в 17:35"), ["в"])
        XCTAssertEqual(Tokenizer().tokens(in: "2024 шо"), ["шо"])
    }

    func testLatinWordIsSingleToken() {
        XCTAssertEqual(Tokenizer().tokens(in: "hello world"), ["hello", "world"])
    }

    // MARK: Нормализация палочки

    func testCanonicalReplacesAllSubstitutions() {
        let p = String(Palochka.character)
        XCTAssertEqual(Normalizer.canonical("г1ала"), "г1ала".replacingOccurrences(of: "1", with: p))
        XCTAssertEqual(Normalizer.canonical("Iалам"), p + "алам")
        XCTAssertEqual(Normalizer.canonical("lам"), p + "ам")
        XCTAssertEqual(Normalizer.canonical("баркалла"), "баркалла")
    }

    func testUppercasePalochkaCanonizedToLowercase() {
        // Заглавная U+04C0 и строчная U+04CF — одна и та же буква.
        let upper = String(Palochka.uppercaseCharacter)
        let lower = String(Palochka.character)
        XCTAssertEqual(Normalizer.canonical("г" + upper + "ала"),
                       "г" + lower + "ала")
        XCTAssertEqual(Palochka.canonize(upper.first!), lower.first!)
    }

    func testMixedAlphabetIsStrongEvidence() {
        XCTAssertTrue(Normalizer.isMixedAlphabet("хIорд"))
        XCTAssertFalse(Normalizer.isMixedAlphabet("привет"))
        XCTAssertFalse(Normalizer.isMixedAlphabet("hello"))
    }

    func testHypothesesEnumerateSubsets() {
        let fullReplacement = String(Palochka.character) + "алам"
        let hypotheses = Set(Normalizer.hypotheses(for: "1алам"))
        XCTAssertTrue(hypotheses.contains(fullReplacement))
        XCTAssertTrue(hypotheses.contains("1алам"))
        XCTAssertEqual(hypotheses.count, 2)
        XCTAssertEqual(Normalizer.hypotheses(for: "дела"), ["дела"])
    }

    // MARK: Сборка словаря

    private static func makeBuilder(_ source: SourceConfig, texts: [String]) -> LexiconBuilder {
        let builder = LexiconBuilder()
        for text in texts { builder.add(source: source, text: text) }
        return builder
    }

    private static let dictSource = SourceConfig(id: "dictionary", url: "",
                                                 revision: "test", maxShare: 1.0)

    func testDuplicatesWithDifferentPalochkaAreMerged() throws {
        // «г1ала» (подмена), «гӀала» (заглавная U+04C0) и каноническая форма —
        // три написания одного слова; частоты складываются.
        let builder = Self.makeBuilder(
            Self.dictSource,
            texts: ["г1ала г" + String(Palochka.uppercaseCharacter) + "ала г1ала"]
        )
        let (entries, _) = builder.finalize(minCount: 2)
        XCTAssertEqual(entries.first?.word, "г" + String(Palochka.character) + "ала")
        XCTAssertEqual(entries.first?.count ?? 0, 3)
        XCTAssertEqual(entries.count, 1)
    }

    func testMinCountDropsHapaxLegomena() {
        let builder = Self.makeBuilder(Self.dictSource,
                                       texts: ["дела дела кхоъ"])
        let (entries, _) = builder.finalize(minCount: 2)
        XCTAssertTrue(entries.contains { $0.word == "дела" })
        XCTAssertNil(entries.first { $0.word == "кхоъ" })
    }

    func testCapitalOnlyFlagMarksProperNouns() {
        let builder = Self.makeBuilder(Self.dictSource,
                                       texts: ["Москва Москва со"])
        let (entries, _) = builder.finalize(minCount: 2)
        XCTAssertEqual(entries.first { $0.word == "москва" }?.capitalOnly, true)
    }

    func testLatinWordsFilteredOut() {
        let builder = Self.makeBuilder(Self.dictSource,
                                       texts: ["hello hello hello"])
        let (entries, _) = builder.finalize(minCount: 2)
        XCTAssertTrue(entries.isEmpty)
    }

    func testSourceCapLimitsScriptureDominance() {
        let scripture = SourceConfig(id: "scripture", url: "", revision: "t",
                                     maxShare: 0.25)
        let daily = SourceConfig(id: "daily", url: "", revision: "t",
                                 maxShare: 1.0)
        let builder = LexiconBuilder()
        builder.add(source: scripture, text: String(repeating: "дош ", count: 100))
        builder.add(source: daily, text: String(repeating: "басе ", count: 10))

        let (entries, stats) = builder.finalize(minCount: 1)
        let scriptureWord = entries.first { $0.word == "дош" }!.count
        let dailyWord = entries.first { $0.word == "басе" }!.count
        // Без потолка разрыв был бы 10x; после ограничения — заметно меньше.
        XCTAssertLessThan(scriptureWord / dailyWord, 4)
        XCTAssertLessThan(stats.scalingFactors["scripture"]!, 1.0)
    }

    func testUkrainianICanonicalizedInBothCases() {
        // Корпус lingtrain использует заглавную украинскую І (U+0406),
        // пользователи со украинской раскладкой могут ввести строчную
        // U+0456 — обе сводятся к канонической палочке U+04CF.
        let p = String(Palochka.character)
        XCTAssertEqual(Normalizer.canonical("т\u{0456}е"), "т" + p + "е")
        XCTAssertEqual(Normalizer.canonical("Т\u{0406}е".lowercased()), "т" + p + "е")
        XCTAssertTrue(Palochka.isSubstitution("\u{0456}"))
        XCTAssertTrue(Palochka.isSubstitution("\u{0406}"))
    }

    func testCoverageRecognizesCanonicalForms() throws {
        let p = String(Palochka.character)
        let builder = Self.makeBuilder(Self.dictSource,
                                       texts: ["г1ала бина дела ду"])
        let (entries, _) = builder.finalize(minCount: 1)
        let lexicon = Set(entries.map(\.word))
        // Вход с подменой «1» и заглавной буквой должен узнаваться.
        let report = Coverage.measure(lexicon: lexicon,
                                      text: "Г1ала бина дела ду.")
        XCTAssertEqual(report.ratio, 1.0, accuracy: 0.0001)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

private extension String {
    func appending(_ suffix: String) -> String { self + suffix }
}
