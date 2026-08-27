import AppKit
import CryptoKit
import XCTest

@MainActor
final class ClipboardStoreTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0xA5, count: 32))

    private func makeStore(at url: URL, key: SymmetricKey? = nil,
                           maxEntries: Int = 20, retentionDays: Int = 0,
                           byteBudget: Int = ClipboardStore.totalByteBudget) -> ClipboardStore {
        ClipboardStore(preparedKey: (key ?? self.key, true), storageURL: url,
                       maxEntries: maxEntries, retentionDays: retentionDays,
                       byteBudget: byteBudget)
    }

    func testPasteboardTypeLabels() {
        XCTAssertEqual(PasteboardCategories.labels(for: [.string]), ["текст"])
        XCTAssertEqual(PasteboardCategories.labels(for: [.rtf, .png, .fileURL]),
                       ["форматированный текст", "изображение", "файл/папка"])
    }

    /// Спасение ключа из связки обязано случиться не больше одного раза
    /// на конкретную историю: иначе отказ в доступе возвращал бы диалог
    /// «Разрешить всегда» при каждом запуске.
    func testKeychainIsAskedOncePerHistoryFile() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("debug-history.rescue-failed")
        let first = "aaaa1111"
        let second = "bbbb2222"

        // Отметки нет — спрашиваем.
        XCTAssertTrue(ClipboardStore.shouldAskKeychain(fingerprint: first, marker: marker))

        // Записали неудачу для этой истории — больше не спрашиваем.
        try first.write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertFalse(ClipboardStore.shouldAskKeychain(fingerprint: first, marker: marker))

        // Другая история — новая попытка.
        XCTAssertTrue(ClipboardStore.shouldAskKeychain(fingerprint: second, marker: marker))

        // Перевод строки в конце файла не должен ломать сравнение.
        try (first + "\n").write(to: marker, atomically: true, encoding: .utf8)
        XCTAssertFalse(ClipboardStore.shouldAskKeychain(fingerprint: first, marker: marker))
    }

    /// Если файл ключа не удалось удалить, ключевой материал обязан быть
    /// затёрт: открытый ключ на диске хуже отсутствующего.
    func testUndeletableKeyFileIsWipedInstead() throws {
        let directory = try TestFiles.directory()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        let key = directory.appendingPathComponent("debug-history.key")
        try Data(repeating: 0x5A, count: 32).write(to: key)

        // Каталог без права записи — удалить файл из него нельзя.
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        ClipboardStore.discardKeyFile(at: key)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        // Файл ОБЯЗАН остаться на месте: каталог был закрыт на запись,
        // значит удаление невозможно и сработала именно ветка затирания.
        XCTAssertTrue(manager.fileExists(atPath: key.path),
                      "тест не проверил бы затирание, если файл просто удалился")
        let left = try Data(contentsOf: key)
        XCTAssertTrue(left.isEmpty, "ключевой материал остался лежать открытым")
    }

    /// Отсутствующий файл — не повод пугать пользователя требованием
    /// удалить что-то вручную.
    func testDiscardingMissingKeyFileIsSilent() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("debug-history.key")
        ClipboardStore.discardKeyFile(at: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    /// Различие «истории нет» / «не открывается» / «не прочиталась» —
    /// основание для решения удалить ключ. Раньше все три случая давали
    /// один ответ, и сбой чтения приводил к уничтожению годного ключа.
    func testHistoryStateSeparatesAbsentFromUnreadable() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clipboard-history.bin")
        let other = SymmetricKey(data: Data(repeating: 0x11, count: 32))

        XCTAssertEqual(ClipboardStore.historyState(for: key, at: url), .absent)

        try Data().write(to: url)
        XCTAssertEqual(ClipboardStore.historyState(for: key, at: url), .absent,
                       "пустой файл — терять нечего")

        // Настоящая история, зашифрованная нашим ключом.
        let store = makeStore(at: url)
        store.add(text: "запись", sourceAppBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(ClipboardStore.historyState(for: key, at: url), .opens)
        XCTAssertEqual(ClipboardStore.historyState(for: other, at: url), .doesNotOpen,
                       "чужой ключ обязан отличаться от подходящего")

        // Мусор вместо шифртекста: ответа нет, и делать выводы нельзя.
        try Data(repeating: 0x7F, count: 8).write(to: url)
        XCTAssertEqual(ClipboardStore.historyState(for: key, at: url), .unreadable)
    }

    /// «Файла нет» и «не удалось проверить» — разные ответы. Второй не
    /// должен выглядеть как первый: на «нет файла» опирается решение
    /// перезаписать историю и удалить ключ.
    func testFileStateSeparatesAbsentFromUncheckable() throws {
        let directory = try TestFiles.directory()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        let file = directory.appendingPathComponent("clipboard-history.bin")
        XCTAssertEqual(ClipboardStore.fileState(at: file), .absent)

        try Data(repeating: 0x1, count: 4).write(to: file)
        XCTAssertEqual(ClipboardStore.fileState(at: file), .present)

        // Каталог без права на чтение и обход: проверить файл невозможно.
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        let blocked = ClipboardStore.fileState(at: file)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(blocked, .unknown,
                       "недоступный каталог не должен читаться как «файла нет»")
    }

    /// Недоступный каталог blob-ов не повод вычёркивать изображение из
    /// истории: «не смог проверить» — не «файла нет».
    func testUncheckableBlobKeepsImageEntry() throws {
        let directory = try TestFiles.directory()
        let manager = FileManager.default
        defer {
            let blobs = directory.appendingPathComponent("history.blobs")
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobs.path)
            try? manager.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("history.bin")
        // Хранилищу важны байты, а не картинка — как в соседнем тесте.
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0xAB, count: 64)

        let store = makeStore(at: url)
        store.addImage(png: png, label: "снимок", thumbnail: nil,
                       sourceAppBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.entries.count, 1)

        // Каталог blob-ов недоступен: проверить наличие файла нельзя.
        let blobs = directory.appendingPathComponent("history.blobs")
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blobs.path)
        let reopened = makeStore(at: url)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobs.path)
        XCTAssertEqual(reopened.entries.count, 1,
                       "запись стёрта из-за недоступного каталога, а не из-за пропажи файла")
    }

    /// Недоступный файл истории не должен читаться как «первый запуск»:
    /// иначе первая же запись затёрла бы существующие данные.
    func testUncheckableHistoryStaysReadOnly() throws {
        let directory = try TestFiles.directory()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("history.bin")

        let store = makeStore(at: url)
        store.add(text: "первая", sourceAppBundleID: nil, sourceAppName: nil)
        let before = try Data(contentsOf: url)

        // Каталог недоступен: проверить наличие истории нельзя.
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        let blocked = makeStore(at: url)
        let readOnly = blocked.isReadOnly
        blocked.add(text: "вторая", sourceAppBundleID: nil, sourceAppName: nil)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        XCTAssertTrue(readOnly, "непроверяемая история обязана переводить сессию в read-only")
        XCTAssertEqual(try Data(contentsOf: url), before,
                       "история изменилась, хотя проверить её не удалось")
    }

    /// Спасение ключа проверяется на самой функции спасения, а не в обход
    /// неё: важны перебор окон, отказ при неподходящих байтах и — главное —
    /// отказ ЗАМЕНЯТЬ, когда историю прочитать не удалось.
    func testSalvageRecoversPaddedKeyAndRefusesWhenUnverifiable() throws {
        let directory = try TestFiles.directory()
        let manager = FileManager.default
        defer {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? manager.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("history.bin")
        let store = makeStore(at: url)
        store.add(text: "запись", sourceAppBundleID: nil, sourceAppName: nil)
        let raw = key.withUnsafeBytes { Data($0) }

        // Лишние байты по краям — ключ достаётся окном.
        let padded = Data([0xDE]) + raw + Data([0xAD, 0xBE])
        guard case let .recovered(found) = ClipboardStore.salvagedKey(
            from: padded, historyAt: url) else {
            return XCTFail("ключ с лишними байтами не восстановлен")
        }
        XCTAssertEqual(found.withUnsafeBytes { Data($0) }, raw)

        // base64 того же ключа.
        let encoded = Data(raw.base64EncodedString().utf8)
        guard case .recovered = ClipboardStore.salvagedKey(from: encoded, historyAt: url) else {
            return XCTFail("base64-ключ не восстановлен")
        }

        // Мусор той же длины: ни один кандидат не подошёл. Это НЕ повод
        // затирать байты — на существующей истории «не подошёл» может
        // означать повреждённый файл при правильном ключе.
        let junk = Data(repeating: 0x5C, count: padded.count)
        guard case .unverifiable = ClipboardStore.salvagedKey(from: junk, historyAt: url) else {
            return XCTFail("отказ на существующей истории обязан быть unverifiable")
        }

        // Слишком большой элемент не разбираем вовсе — и тоже не затираем.
        guard case .unverifiable = ClipboardStore.salvagedKey(
            from: Data(repeating: 0x1, count: 8192), historyAt: url) else {
            return XCTFail("превышение объёма должно отсекаться без разрушения")
        }

        // Истории нет — терять нечего, замена разрешена.
        let missing = directory.appendingPathComponent("nothing.bin")
        guard case .hopeless = ClipboardStore.salvagedKey(from: junk, historyAt: missing) else {
            return XCTFail("при отсутствии истории замена должна быть разрешена")
        }

        // Пустой файл — тоже файл: мог остаться от неудачной записи.
        let blank = directory.appendingPathComponent("blank.bin")
        try Data().write(to: blank)
        guard case .hopeless = ClipboardStore.salvagedKey(from: junk, historyAt: blank) else {
            return XCTFail("пустой файл без резервной копии терять нечего")
        }

        // ...но если рядом лежит резервная копия нечитаемой истории, она
        // зашифрована ТЕМ ЖЕ ключом — байты неприкосновенны.
        try Data(repeating: 0xEE, count: 64).write(
            to: directory.appendingPathComponent("blank.unreadable.bin"))
        guard case .unverifiable = ClipboardStore.salvagedKey(from: junk, historyAt: blank) else {
            return XCTFail("при наличии резервной копии замена запрещена")
        }
        try Data(repeating: 0xEE, count: 64).write(
            to: directory.appendingPathComponent("nothing.unreadable.bin"))
        guard case .unverifiable = ClipboardStore.salvagedKey(from: junk, historyAt: missing) else {
            return XCTFail("резервная копия защищает и при отсутствующем файле истории")
        }

        // История недоступна — проверить кандидатов нечем, замена запрещена.
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
        let blocked = ClipboardStore.salvagedKey(from: padded, historyAt: url)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard case .unverifiable = blocked else {
            return XCTFail("нечитаемая история обязана давать unverifiable, а не hopeless")
        }
    }

    func testEncryptedRoundTripAndUnreadableGuard() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.bin")
        let sample = "секрет-\(UUID().uuidString)"

        let store = makeStore(at: url)
        store.add(text: sample, sourceAppBundleID: nil, sourceAppName: nil)
        let encrypted = try Data(contentsOf: url)
        XCTAssertFalse(encrypted.isEmpty)
        XCTAssertNil(encrypted.range(of: Data(sample.utf8)))
        XCTAssertEqual(makeStore(at: url).entries.first?.text, sample)

        let bytesBeforeUnreadableLoad = try Data(contentsOf: url)
        let wrongKey = SymmetricKey(data: Data(repeating: 0x5A, count: 32))
        let unreadable = makeStore(at: url, key: wrongKey)
        XCTAssertTrue(unreadable.entries.isEmpty)
        XCTAssertTrue(unreadable.isReadOnly)
        unreadable.add(text: "must-not-overwrite", sourceAppBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(try Data(contentsOf: url), bytesBeforeUnreadableLoad)
    }

    func testRetentionAndByteBudgetRemoveOldestNonFavorite() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let retentionURL = directory.appendingPathComponent("retention.bin")
        let retained = makeStore(at: retentionURL, retentionDays: 7)
        retained.add(text: "favorite", sourceAppBundleID: nil, sourceAppName: nil)
        retained.toggleFavorite(id: retained.entries[0].id)
        retained.backdate(id: retained.entries[0].id,
                          to: Date().addingTimeInterval(-8 * 86_400))
        retained.add(text: "expired", sourceAppBundleID: nil, sourceAppName: nil)
        retained.backdate(id: retained.entries[0].id,
                          to: Date().addingTimeInterval(-8 * 86_400))
        XCTAssertEqual(makeStore(at: retentionURL, retentionDays: 7).entries.map(\.text),
                       ["favorite"])

        let budgetURL = directory.appendingPathComponent("budget.bin")
        let budget = makeStore(at: budgetURL, byteBudget: 200)
        for suffix in ["one", "two", "three"] {
            budget.add(text: String(repeating: "x", count: 90) + suffix,
                       sourceAppBundleID: nil, sourceAppName: nil)
        }
        XCTAssertEqual(budget.entries.count, 2)
        XCTAssertTrue(budget.entries[0].text.hasSuffix("three"))
        XCTAssertFalse(budget.entries.contains { $0.text.hasSuffix("one") })
    }

    func testBlobDeleteUndoAndFinalizeLifecycle() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rich.bin")
        let blobs = url.deletingPathExtension().appendingPathExtension("blobs")
        let pngMagic = Data([0x89, 0x50, 0x4E, 0x47])
        let png = pngMagic + Data(repeating: 0xAB, count: 64)
        let store = makeStore(at: url)

        store.addImage(png: png, label: "image", thumbnail: Data([1, 2]),
                       sourceAppBundleID: nil, sourceAppName: nil)
        let entry = try XCTUnwrap(store.entries.first)
        let blobURL = blobs.appendingPathComponent(entry.id.uuidString + ".bin")
        XCTAssertEqual(store.imageData(for: entry), png)
        XCTAssertNil(try Data(contentsOf: blobURL).range(of: pngMagic))

        let deleted = try XCTUnwrap(store.delete(id: entry.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))
        store.restore(deleted)
        XCTAssertEqual(store.imageData(for: entry), png)
        let deletedAgain = try XCTUnwrap(store.delete(id: entry.id))
        store.finalizeDelete(deletedAgain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path))
    }

    func testMassDeleteSkipsFavoriteAndRestoresBatch() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory.appendingPathComponent("batch.bin"))
        store.add(text: "favorite", sourceAppBundleID: nil, sourceAppName: nil)
        store.toggleFavorite(id: store.entries[0].id)
        store.add(text: "first", sourceAppBundleID: nil, sourceAppName: nil)
        store.add(text: "second", sourceAppBundleID: nil, sourceAppName: nil)

        let batch = store.deleteBatch(ids: store.entries.map(\.id))
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(store.entries.map(\.text), ["favorite"])
        batch.forEach(store.restore)
        XCTAssertEqual(Set(store.entries.map(\.text)), ["favorite", "first", "second"])
    }

    func testLockWipesMemoryWithoutPersistingMutations() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("lock.bin")
        let store = makeStore(at: url)
        store.add(text: "before-lock", sourceAppBundleID: nil, sourceAppName: nil)
        let ids = store.entries.map(\.id)

        store.wipeInMemory()
        XCTAssertTrue(store.entries.isEmpty)
        store.add(text: "during-lock", sourceAppBundleID: nil, sourceAppName: nil)
        store.reloadFromDisk()
        XCTAssertEqual(store.entries.map(\.id), ids)
        XCTAssertFalse(store.entries.contains { $0.text == "during-lock" })
    }
}
