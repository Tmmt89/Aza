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
