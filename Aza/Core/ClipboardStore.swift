import Combine
import CryptoKit
import Foundation

/// Одна запись истории буфера обмена.
struct ClipEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var createdAt: Date
    /// Bundle ID приложения-источника, если удалось определить.
    var sourceAppBundleID: String?
    /// Локализованное имя приложения-источника.
    var sourceAppName: String?
}

/// Хранилище истории буфера: AES-GCM (CryptoKit) на диске, ключ —
/// в Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly). Файл —
/// Application Support/Aza/clipboard-history.bin.
///
/// Самопроверка шифрования выполняется при старте Debug-сборки
/// (`runSelfTest`): раундтрип, отсутствие открытого текста на диске
/// и отказ «расшифровывать» подменённый файл.
@MainActor
final class ClipboardStore: ObservableObject {

    static let maxEntries = 200
    static let maxItemCharacters = 100_000

    @Published private(set) var entries: [ClipEntry] = []

    private let storageURL: URL
    private let key: SymmetricKey

    private struct Payload: Codable {
        var version = 1
        var entries: [ClipEntry]
    }

    // MARK: Инициализация

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        key = Self.loadOrCreateKey()
        load()
    }

    static func defaultStorageURL() -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aza", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("clipboard-history.bin")
    }

    // MARK: Публичный API

    /// Добавляет запись: дедупликация (повторное копирование поднимает
    /// запись наверх с новой датой), обрезка по длине и объёму истории.
    func add(text: String, sourceAppBundleID: String?, sourceAppName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.count <= Self.maxItemCharacters else { return }

        if let index = entries.firstIndex(where: { $0.text == trimmed }) {
            var moved = entries.remove(at: index)
            moved.createdAt = Date()
            entries.insert(moved, at: 0)
            save()
            return
        }

        entries.insert(ClipEntry(
            id: UUID(), text: trimmed, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName
        ), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    func entry(id: UUID) -> ClipEntry? {
        entries.first { $0.id == id }
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    // MARK: Шифрование и диск

    private func save() {
        do {
            let payload = try JSONEncoder().encode(Payload(entries: entries))
            let sealed = try AES.GCM.seal(payload, using: key).combined!
            try sealed.write(to: storageURL, options: .atomic)
        } catch {
            #if DEBUG
            print("ClipboardStore.save error:", error.localizedDescription)
            #endif
        }
    }

    private func load() {
        guard let sealedData = try? Data(contentsOf: storageURL),
              !sealedData.isEmpty,
              let box = try? AES.GCM.SealedBox(combined: sealedData),
              let payload = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder().decode(Payload.self, from: payload) else {
            return
        }
        entries = decoded.entries
    }

    // MARK: Ключ в Keychain

    private static func loadOrCreateKey() -> SymmetricKey {
        let service = "com.tmmt.Aza.clipboard"
        let account = "history-key"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return SymmetricKey(data: data)
        }

        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecReturnData as String] = nil
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(add as CFDictionary, nil)
        assert(status == errSecSuccess, "Keychain: не удалось сохранить ключ (\(status))")
        return key
    }

    // MARK: Самопроверка (Debug)

    /// Раундтрип шифрования на временном файле. Проверяет: запись читается
    /// обратно, на диске нет открытого текста, подменённый файл молча
    /// игнорируется (AES-GCM tag не сойдётся).
    static func runSelfTest(sample: String) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aza-clipboard-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = ClipboardStore(storageURL: tempURL)
        store.add(text: sample, sourceAppBundleID: nil, sourceAppName: nil)
        assert(store.entries.first?.text == sample)

        let rawOnDisk = (try? Data(contentsOf: tempURL)) ?? Data()
        assert(!rawOnDisk.isEmpty)
        assert(rawOnDisk.range(of: Data(sample.utf8)) == nil, "plaintext leaked to disk")

        let reloaded = ClipboardStore(storageURL: tempURL)
        assert(reloaded.entries.first?.text == sample)

        try? Data([0x00, 0x01, 0x02]).write(to: tempURL)
        assert(ClipboardStore(storageURL: tempURL).entries.isEmpty)
    }
}
