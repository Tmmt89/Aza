import XCTest

@MainActor
final class PhraseStoreTests: XCTestCase {

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
