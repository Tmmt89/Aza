import AppKit
import CryptoKit
import Darwin
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

    func testLocalKeyPersistsWithPrivatePermissionsAndOpensHistory() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("Aza/history.bin")
        let keyFile = history.deletingLastPathComponent()
            .appendingPathComponent(ClipboardStore.localKeyFileName)
        let first = ClipboardStore.obtainKey(storageURL: history)
        XCTAssertTrue(first.1)
        let raw = try Data(contentsOf: keyFile)
        XCTAssertEqual(raw.count, 32)
        XCTAssertEqual(first.0.withUnsafeBytes { Data($0) }, raw)
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int, 0o600)
        let directoryAttributes = try manager.attributesOfItem(
            atPath: keyFile.deletingLastPathComponent().path)
        XCTAssertEqual(directoryAttributes[.posixPermissions] as? Int, 0o700)

        let store = ClipboardStore(preparedKey: first, storageURL: history)
        store.add(text: "сохранённая запись", sourceAppBundleID: nil, sourceAppName: nil)
        let encrypted = try Data(contentsOf: history)
        XCTAssertNil(encrypted.range(of: Data("сохранённая запись".utf8)))
        // Повторный запуск использует тот же ключ и восстанавливает права.
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)
        let second = ClipboardStore.obtainKey(storageURL: history)
        XCTAssertTrue(second.1)
        XCTAssertEqual(second.0.withUnsafeBytes { Data($0) }, raw)
        XCTAssertEqual(try manager.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(ClipboardStore(preparedKey: second, storageURL: history).entries.first?.text,
                       "сохранённая запись")
    }

    func testMissingOrDamagedLocalKeyLeavesExistingHistoryReadOnly() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        for mode in ["missing", "damaged", "unreadable", "wrong-legacy"] {
            let root = directory.appendingPathComponent(mode)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let history = root.appendingPathComponent("history.bin")
            let keyFile = root.appendingPathComponent(
                mode == "wrong-legacy" ? "debug-history.key" : ClipboardStore.localKeyFileName)
            makeStore(at: history).add(text: "не стирать", sourceAppBundleID: nil, sourceAppName: nil)
            let before = try Data(contentsOf: history)
            let keyBytes = Data(repeating: 0x11, count: mode == "damaged" ? 31 : 32)
            if mode != "missing" { try keyBytes.write(to: keyFile) }
            if mode == "unreadable" {
                try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyFile.path)
            }
            let prepared = ClipboardStore.obtainKey(storageURL: history)
            XCTAssertFalse(prepared.1, mode)
            let store = ClipboardStore(preparedKey: prepared, storageURL: history)
            XCTAssertTrue(store.isReadOnly, mode)
            store.add(text: "не перезаписывать", sourceAppBundleID: nil, sourceAppName: nil)
            XCTAssertEqual(try Data(contentsOf: history), before, mode)
            if mode == "missing" {
                XCTAssertFalse(manager.fileExists(atPath: keyFile.path))
            } else {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
                XCTAssertEqual(try Data(contentsOf: keyFile), keyBytes, mode)
            }
        }
    }

    func testLocalKeyDoesNotFollowLinksOrReadSpecialFiles() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let history = directory.appendingPathComponent("history.bin")
        let keyFile = directory.appendingPathComponent(ClipboardStore.localKeyFileName)
        let target = directory.appendingPathComponent("target.key")
        let raw = key.withUnsafeBytes { Data($0) }
        try raw.write(to: target)
        try manager.createSymbolicLink(at: keyFile, withDestinationURL: target)
        XCTAssertFalse(ClipboardStore.obtainKey(storageURL: history).1)
        XCTAssertEqual(try Data(contentsOf: target), raw)
        try manager.removeItem(at: target)
        XCTAssertFalse(ClipboardStore.obtainKey(storageURL: history).1,
                       "dangling link must not be replaced")
        try manager.removeItem(at: keyFile)
        try manager.createDirectory(at: keyFile, withIntermediateDirectories: false)
        XCTAssertFalse(ClipboardStore.obtainKey(storageURL: history).1)
        try manager.removeItem(at: keyFile)
        XCTAssertEqual(mkfifo(keyFile.path, 0o600), 0)
        XCTAssertFalse(ClipboardStore.obtainKey(storageURL: history).1,
                       "FIFO must not hang the loader")
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

    /// Транскрипт диктовки помечается флагом, переживает диск, а повторная
    /// диктовка текста, уже лежащего в истории, помечает существующую
    /// запись; обычное копирование транскрипта флаг не снимает.
    func testTranscriptFlagPersistsAndDedupMarks() throws {
        let url = try TestFiles.directory().appendingPathComponent("history.bin")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = makeStore(at: url)
        store.add(text: "диктовка", sourceAppBundleID: nil, sourceAppName: nil,
                  isTranscript: true)
        store.add(text: "копия", sourceAppBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.entries.map { $0.isTranscript == true }, [false, true])

        // Дедуп: диктовка того же текста помечает существующую запись…
        store.add(text: "копия", sourceAppBundleID: nil, sourceAppName: nil,
                  isTranscript: true)
        // …а копирование текста транскрипта флаг не снимает.
        store.add(text: "диктовка", sourceAppBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.entries.map { $0.isTranscript == true }, [true, true])

        let reopened = makeStore(at: url)
        XCTAssertEqual(reopened.entries.map { $0.isTranscript == true }, [true, true])
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

    func testLegacyMigrationPreservesKeyHistoryBackupAndImages() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = FileManager.default
        let raw = key.withUnsafeBytes { Data($0) }
        for legacyBytes in [raw, Data([0xDE]) + raw + Data([0xAD])] {
            let root = directory.appendingPathComponent(UUID().uuidString)
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let history = root.appendingPathComponent("clipboard-history.bin")
            let legacy = root.appendingPathComponent("debug-history.key")
            let keyFile = root.appendingPathComponent(ClipboardStore.localKeyFileName)
            makeStore(at: history).add(text: "прежняя история", sourceAppBundleID: nil, sourceAppName: nil)
            let before = try Data(contentsOf: history)
            try legacyBytes.write(to: legacy)
            let backup = ClipboardStore.unreadableBackupURL(for: history)
            let backupBytes = try XCTUnwrap(AES.GCM.seal(Data("старая копия".utf8),
                using: SymmetricKey(size: .bits256)).combined)
            try backupBytes.write(to: backup)
            let blobs = history.deletingPathExtension().appendingPathExtension("blobs")
            try manager.createDirectory(at: blobs, withIntermediateDirectories: false)
            let backupImage = blobs.appendingPathComponent("backup-image.bin")
            try Data([1, 2, 3]).write(to: backupImage)

            let prepared = ClipboardStore.obtainKey(storageURL: history)
            XCTAssertTrue(prepared.1)
            XCTAssertEqual(try Data(contentsOf: keyFile), raw)
            XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
            XCTAssertEqual(try Data(contentsOf: history), before)
            XCTAssertEqual(try Data(contentsOf: backup), backupBytes)
            XCTAssertEqual(ClipboardStore(preparedKey: prepared, storageURL: history)
                .entries.first?.text, "прежняя история")
            XCTAssertEqual(try Data(contentsOf: backupImage), Data([1, 2, 3]),
                           "images possibly referenced by the backup must survive")
            XCTAssertTrue(ClipboardStore.obtainKey(storageURL: history).1)
            XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
        }
    }

    func testBackupOrOrphanImagesBlockFreshKeyCreation() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = directory.appendingPathComponent("history.bin")
        let backup = ClipboardStore.unreadableBackupURL(for: history)
        let keyFile = directory.appendingPathComponent(ClipboardStore.localKeyFileName)
        try Data([1, 2, 3]).write(to: backup)
        XCTAssertFalse(ClipboardStore.obtainKey(storageURL: history).1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
        XCTAssertEqual(try Data(contentsOf: backup), Data([1, 2, 3]))
        try FileManager.default.removeItem(at: backup)
        let blobs = history.deletingPathExtension().appendingPathExtension("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: false)
        let image = blobs.appendingPathComponent("image.bin")
        try Data([4, 5, 6]).write(to: image)
        XCTAssertFalse(ClipboardStore.obtainKey(storageURL: history).1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyFile.path))
        XCTAssertEqual(try Data(contentsOf: image), Data([4, 5, 6]))
        try FileManager.default.removeItem(at: image)
        XCTAssertTrue(ClipboardStore.obtainKey(storageURL: history).1,
                      "an empty blob directory must not block a clean start")
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
        store.addImage(png: Data([1, 2, 3]), label: "image", thumbnail: nil,
                       sourceAppBundleID: nil, sourceAppName: nil)
        let image = try XCTUnwrap(store.entries.first)
        let deleted = try XCTUnwrap(store.delete(id: image.id))

        store.wipeInMemory()
        XCTAssertTrue(store.entries.isEmpty)
        store.add(text: "during-lock", sourceAppBundleID: nil, sourceAppName: nil)
        store.addRTF(text: "rich", rtf: Data([1]), sourceAppBundleID: nil, sourceAppName: nil)
        store.addFiles(paths: ["/tmp/file"], sourceAppBundleID: nil, sourceAppName: nil)
        store.addLink(URL(string: "https://example.com")!, sourceAppBundleID: nil, sourceAppName: nil)
        store.restore(deleted)
        XCTAssertTrue(store.entries.isEmpty, "Locked history must stay empty in memory, too")
        XCTAssertNil(store.imageData(for: image), "Stale cards must not decrypt images while locked")
        store.reloadFromDisk()
        XCTAssertEqual(store.entries.map(\.id), ids)
        XCTAssertFalse(store.entries.contains { $0.text == "during-lock" })
    }

    func testRTFPreservesPlainTextWhitespace() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rtf.bin")
        let store = makeStore(at: url)
        let text = "  indented text\n"
        let attributed = NSAttributedString(string: text)
        let rtf = try XCTUnwrap(attributed.rtf(
            from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]))
        store.addRTF(text: text, rtf: rtf, sourceAppBundleID: nil, sourceAppName: nil)
        XCTAssertEqual(store.entries.first?.text, text)
        XCTAssertEqual(makeStore(at: url).entries.first?.text, text)
    }

    func testStoppingMonitorDiscardsPendingImageAfterRestart() async throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(at: directory.appendingPathComponent("image.bin"))
        let monitor = PasteboardMonitor(store: store)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { monitor.stop(); pasteboard.releaseGlobally() }
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.setColor(.red, atX: 0, y: 0)
        pasteboard.setData(try XCTUnwrap(rep.representation(using: .png, properties: [:])),
                           forType: .png)
        monitor.start()
        monitor.classify(pasteboard, sourceAppBundleID: nil, sourceAppName: nil)
        monitor.stop()
        monitor.start()
        // Дождаться декодирования и затем уже поставленной в main записи.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            PasteboardMonitor.imageDecodeQueue.async {
                DispatchQueue.main.async { done.resume() }
            }
        }
        XCTAssertTrue(store.entries.isEmpty)

        monitor.classify(pasteboard, sourceAppBundleID: nil, sourceAppName: nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            PasteboardMonitor.imageDecodeQueue.async {
                DispatchQueue.main.async { done.resume() }
            }
        }
        XCTAssertEqual(store.entries.first?.resolvedKind, .image)
    }
}
