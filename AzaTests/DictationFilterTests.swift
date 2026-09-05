import XCTest

@MainActor
final class DictationFilterTests: XCTestCase {
    func testFillerCleanupPreservesMeasurementsAndPunctuation() {
        for text in ["Диаметр 10 мм.", "Зазор 2 мм, длина 30 мм.", "Толщина в мм: 0,5."] {
            XCTAssertEqual(DictationFilters.removingFillerSounds(from: text), text)
        }
        XCTAssertEqual(DictationFilters.removingFillerSounds(from: "Эм, диаметр 10 мм."),
                       "Диаметр 10 мм.")
    }

    func testWhisperCacheRequiresEveryModelComponentAndNonemptyWeights() throws {
        let folder = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertFalse(DictationController.isModelCached(in: folder))
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let model = folder.appendingPathComponent(component + ".mlmodelc")
            try FileManager.default.createDirectory(at: model.appendingPathComponent("weights"),
                                                     withIntermediateDirectories: true)
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                XCTAssertFalse(DictationController.isModelCached(in: folder))
                try Data([1]).write(to: model.appendingPathComponent(file))
            }
        }
        XCTAssertTrue(DictationController.isModelCached(in: folder))
        let weights = folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin")
        try Data().write(to: weights)
        XCTAssertFalse(DictationController.isModelCached(in: folder))
        try FileManager.default.removeItem(at: weights)
        XCTAssertFalse(DictationController.isModelCached(in: folder))
    }

    func testLockAndDeletionRejectStaleDictationResults() {
        var session = DictationSession()
        let captured = session.generation
        XCTAssertTrue(session.accepts(captured))

        session.isLocked = true
        session.invalidate()
        XCTAssertFalse(session.canStart)
        XCTAssertFalse(session.accepts(captured))
        session.isLocked = false
        XCTAssertTrue(session.canStart)
        XCTAssertFalse(session.accepts(captured), "разблокировка не оживляет отменённый результат")

        let beforeDeletion = session.generation
        session.isDeletingModels = true
        session.invalidate()
        XCTAssertFalse(session.canStart, "новая запись запрещена на всём async-удалении")
        session.isDeletingModels = false
        XCTAssertFalse(session.accepts(beforeDeletion))
        XCTAssertTrue(session.accepts(session.generation))
    }

    func testSilenceGate() {
        // Чистая тишина и шум ниже порога — не речь.
        XCTAssertFalse(DictationFilters.hasSpeech([Float](repeating: 0, count: 16000)))
        XCTAssertFalse(DictationFilters.hasSpeech(
            [Float](repeating: 0.001, count: 16000)))
        // Один громкий всплеск (100 мс) среди тишины — уже речь.
        var speech = [Float](repeating: 0, count: 16000)
        for index in 8000..<9600 { speech[index] = 0.1 }
        XCTAssertTrue(DictationFilters.hasSpeech(speech))
    }

    func testHallucinatedSegmentsDropped() {
        XCTAssertEqual(
            DictationFilters.reliableText(segments: [
                (" Привет, мир.", -0.3, 0.1),
                (" Субтитры сделал DimaTorzok", -1.5, 0.9),
            ]),
            "Привет, мир.")
        // Спец-токены из текста сегмента вычищаются.
        XCTAssertEqual(
            DictationFilters.reliableText(segments: [("<|ru|> Привет.<|endoftext|>", 0, 0)]),
            "Привет.")
    }

    func testFillerSoundsRemoved() {
        // Паразит в начале уходит вместе с запятой, заглавная восстанавливается.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "Эм, привет, мир."),
            "Привет, мир.")
        // В середине и с дефисами; регистр паразита не важен.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "Я, э-э, думаю, umm, что да."),
            "Я, думаю, что да.")
        // Настоящие слова не трогаются, текст без паразитов — как был.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "Ну вот и всё."),
            "Ну вот и всё.")
        // Внутри слова ничего не режется; паразит в конце уходит без хвоста.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "эмаль и эм"),
            "эмаль и")
        // Заглавная восстанавливается и за открывающей кавычкой.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "Эм, «привет»"),
            "«Привет»")
        // Перенос строки — тоже граница слова и сохраняется, с какой бы
        // стороны от паразита он ни стоял.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "строка,\nэм да"),
            "строка,\nда")
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "готово эм\nследующая"),
            "готово\nследующая")
        // Одиночные «э» и "err" — настоящие слова, не трогаются.
        XCTAssertEqual(
            DictationFilters.removingFillerSounds(from: "Э, постой. To err is human."),
            "Э, постой. To err is human.")
    }

    func testCustomWordFuzzyCorrection() {
        let words = ["Ахьмад", "Соьлжа-ГӀала"]
        // Одна опечатка притягивается, пунктуация и соседи не трогаются.
        XCTAssertEqual(
            DictationFilters.applyingCustomWords(to: "Привет, Ахьмат!", words: words),
            "Привет, Ахьмад!")
        // Палочка-двойник и регистр чинятся формой пользователя.
        XCTAssertEqual(
            DictationFilters.applyingCustomWords(to: "еду в соьлжа-г1ала", words: words),
            "еду в Соьлжа-ГӀала")
        // Далёкое слово и короткие токены не притягиваются.
        XCTAssertEqual(
            DictationFilters.applyingCustomWords(to: "Ахмед да", words: ["Ахьмад"]),
            "Ахмед да")
        // Пустой список — no-op.
        XCTAssertEqual(
            DictationFilters.applyingCustomWords(to: "текст", words: []),
            "текст")
        // Ничья двух разных кандидатов — fail-closed, слово не трогается.
        XCTAssertEqual(
            DictationFilters.applyingCustomWords(to: "Рамиль тут",
                                                 words: ["Камиль", "Самиль"]),
            "Рамиль тут")
        // Многословная запись списка (в т.ч. через таб) пропускается.
        XCTAssertEqual(
            DictationFilters.applyingCustomWords(to: "Дала аьтто",
                                                 words: ["Дала\tаьтто"]),
            "Дала аьтто")
        XCTAssertNil(DictationFilters.levenshtein("абвг", "где", cap: 1))
        XCTAssertEqual(DictationFilters.levenshtein("хало", "хала", cap: 1), 1)
    }

    func testCustomWordsParsing() {
        XCTAssertEqual(
            DictationFilters.words(fromCustomList: " Ахьмад, ,\nСоьлжа-ГӀала "),
            ["Ахьмад", "Соьлжа-ГӀала"])
        XCTAssertEqual(DictationFilters.words(fromCustomList: ""), [])
    }
}
