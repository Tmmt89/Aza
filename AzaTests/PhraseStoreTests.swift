import XCTest

@MainActor
final class PhraseStoreTests: XCTestCase {

    func testFailedWriteAndResetRemainVisibleAndCanBeRetried() throws {
        let directory = try TestFiles.directory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("phrases.json")
        let store = PhraseStore(fileURL: file)
        store.update(0, text: "Saved phrase")
        XCTAssertNil(store.saveError)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        store.update(0, text: "Unsaved draft")
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.phrases[0], "Unsaved draft", "ошибка не теряет набранный текст")
        XCTAssertEqual(PhraseStore(fileURL: file).phrases[0], "Saved phrase")
        store.resetToFactory()
        XCTAssertNotNil(store.saveError)
        XCTAssertEqual(store.phrases[0], "Unsaved draft", "неудачный сброс не меняет фразы")
        XCTAssertTrue(store.isCustomized)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        store.save()
        XCTAssertNil(store.saveError, "неудачный сброс не запрещает дальнейшее сохранение")
        XCTAssertEqual(PhraseStore(fileURL: file).phrases[0], "Unsaved draft")
        store.resetToFactory()
        XCTAssertNil(store.saveError)
        XCTAssertEqual(PhraseStore(fileURL: file).phrases, PhraseStore.factoryPhrases)
        store.resetToFactory()
        XCTAssertNil(store.saveError, "повторный сброс без файла тоже успешен")
    }

    func testDefaultsEditPersistAndReset() throws {
        let url = try TestFiles.directory().appendingPathComponent("phrases.json")

        let store = PhraseStore(fileURL: url)
        XCTAssertEqual(store.phrases, PhraseStore.factoryPhrases)
        XCTAssertFalse(store.isCustomized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        store.update(2, text: "Салам")
        XCTAssertTrue(store.isCustomized)
        XCTAssertEqual(PhraseStore(fileURL: url).phrases[2], "Салам")

        store.resetToFactory()
        XCTAssertEqual(store.phrases, PhraseStore.factoryPhrases)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// «|» делит слот на основной и ⇧-вариант; без «|» оба пути дают одно.
    func testVariantParsing() {
        XCTAssertEqual(PhraseStore.variant("Дала везийла | Дала езийла", alternate: false),
                       "Дала везийла")
        XCTAssertEqual(PhraseStore.variant("Дала везийла | Дала езийла", alternate: true),
                       "Дала езийла")
        XCTAssertEqual(PhraseStore.variant("Баркалла", alternate: true), "Баркалла")
        XCTAssertEqual(PhraseStore.variant("Баркалла |", alternate: true), "Баркалла")
    }

    /// Форма редактирует половины слота: разбор/сборка не теряют текст,
    /// пустой ⇧-вариант не оставляет «|» в хранилище.
    func testPartsJoinRoundTrip() {
        for raw in PhraseStore.factoryPhrases {
            let (main, alt) = PhraseStore.parts(raw)
            XCTAssertEqual(PhraseStore.join(main: main, alt: alt), raw)
        }
        XCTAssertEqual(PhraseStore.join(main: "Баркалла", alt: " "), "Баркалла")
        XCTAssertEqual(PhraseStore.parts("Баркалла").alt, "")
    }

    /// Битый или чужой по форме файл не должен ронять панель — заводские.
    func testUnreadableFileFallsBackToFactory() throws {
        let url = try TestFiles.directory().appendingPathComponent("phrases.json")
        try Data("не json".utf8).write(to: url)
        XCTAssertEqual(PhraseStore(fileURL: url).phrases, PhraseStore.factoryPhrases)
    }
}
