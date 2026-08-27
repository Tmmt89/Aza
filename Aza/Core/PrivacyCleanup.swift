import AppKit
import Foundation
import UserNotifications

/// Удаление локальных данных (§12, критерий готовности §20) и честная
/// опись того, что Aza хранит.
///
/// Уровни, затрагивающие ключ шифрования, ЗАВЕРШАЮТ приложение: ключ
/// лежит у `ClipboardStore` в памяти неизменяемым полем, и продолжать
/// работу после его удаления — значит записать историю ключом, которого
/// уже нет.
@MainActor
enum PrivacyCleanup {

    /// Корень данных Aza. Саму папку и aza.lock не удаляем: снятие лока
    /// на живом процессе открывает окно для второго экземпляра.
    static var directory: URL {
        ClipboardStore.defaultStorageURL().deletingLastPathComponent()
    }

    // MARK: Опись хранимого

    struct Item: Identifiable {
        let id: String
        let title: String
        /// Байты на диске; nil — величина неизвестна (настройки, Keychain).
        let bytes: Int64?
    }

    /// Снимок описи. Считается ВНЕ главного потока: обход папки моделей
    /// (сотни мегабайт и тысячи файлов) на каждой перерисовке панели
    /// подвешивал бы интерфейс.
    static func inventorySnapshot() async -> [Item] {
        let root = directory
        return await Task.detached(priority: .utility) {
            func size(of relative: String) -> Int64? {
                let url = root.appendingPathComponent(relative)
                let manager = FileManager.default
                guard manager.fileExists(atPath: url.path) else { return nil }
                let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                guard values.isDirectory == true else {
                    return Int64(values.totalFileAllocatedSize ?? 0)
                }
                var total: Int64 = 0
                let enumerator = manager.enumerator(at: url,
                                                    includingPropertiesForKeys: Array(keys))
                while let file = enumerator?.nextObject() as? URL {
                    total += Int64((try? file.resourceValues(forKeys: keys))?
                        .totalFileAllocatedSize ?? 0)
                }
                return total
            }

            var items: [Item] = [
                Item(id: "history", title: "История буфера (зашифрована)",
                     bytes: size(of: "clipboard-history.bin")),
                Item(id: "blobs", title: "Изображения истории (зашифрованы)",
                     bytes: size(of: "clipboard-history.blobs")),
                Item(id: "models", title: "Модели распознавания речи",
                     bytes: size(of: "huggingface")),
                Item(id: "words", title: "Слова-исключения",
                     bytes: size(of: "user-words.json")),
            ]
            if let schedules = size(of: "prayer-schedules") {
                items.append(Item(id: "schedules",
                                  title: "Импортированные расписания намаза",
                                  bytes: schedules))
            }
            items.append(Item(id: "defaults", title: "Настройки", bytes: nil))
            return items
        }.value
    }

    static func humanSize(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Что покидает компьютер (§12). Формулировка точная: модель может
    /// скачаться и при запуске — прогрев идёт сам, если микрофон разрешён.
    static let outboundTraffic = """
        Наружу уходит только загрузка модели распознавания с Hugging Face. \
        Она начинается автоматически при запуске, если доступ к микрофону \
        уже выдан, либо при первой диктовке. Буфер, аудио, транскрипты, \
        набранные слова и координаты не отправляются никуда.
        """

    // MARK: Удаление

    /// История буфера и её ключ. Возвращает описание ошибки или nil.
    /// Приложение завершается только при полном успехе: удалить ключ,
    /// оставив нечитаемую историю, хуже, чем не удалить ничего.
    static func deleteClipboardHistory() -> String? {
        if let failure = removeAll([
            "clipboard-history.bin", "clipboard-history.blobs",
            "clipboard-history.unreadable.bin",
        ]) {
            return failure
        }
        if let failure = remove("debug-history.key") { return failure }
        if let failure = deleteKeychainKey() { return failure }
        quit()
    }

    /// Модели восстановимы загрузкой, поэтому выход не нужен. Вызывающий
    /// обязан сперва выгрузить модель из памяти (DictationController),
    /// иначе в ней останется ссылка на исчезнувшие файлы.
    static func deleteModels() -> String? {
        remove("huggingface")
    }

    /// Всё, кроме самой папки и файла блокировки.
    static func deleteEverything() -> String? {
        if let failure = removeAll([
            "clipboard-history.bin", "clipboard-history.blobs",
            "clipboard-history.unreadable.bin", "user-words.json",
            "huggingface", "prayer-schedules",
        ]) {
            return failure
        }
        if let failure = remove("debug-history.key") { return failure }
        if let failure = deleteKeychainKey() { return failure }
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        // Настройки удаляем последними и сразу выходим: обычное завершение
        // успело бы записать @AppStorage обратно.
        UserDefaults.standard.removePersistentDomain(
            forName: Bundle.main.bundleIdentifier ?? "com.tmmt.Aza")
        UserDefaults.standard.synchronize()
        quit()
    }

    /// Возвращает описание первой ошибки; отсутствующий файл ошибкой не
    /// считается.
    private static func remove(_ relative: String) -> String? {
        let url = directory.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: url)
            return nil
        } catch {
            return "\(relative): \(error.localizedDescription)"
        }
    }

    private static func removeAll(_ names: [String]) -> String? {
        for name in names {
            if let failure = remove(name) { return failure }
        }
        return nil
    }

    /// Отсутствие элемента — не ошибка; всё остальное сообщаем, иначе
    /// приложение вышло бы, оставив ключ от удалённой истории.
    private static func deleteKeychainKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tmmt.Aza.clipboard",
            kSecAttrAccount as String: "history-key",
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            return "ключ в связке ключей (\(status))"
        }
        return nil
    }

    /// Резкий выход вместо NSApp.terminate: штатное завершение снова
    /// записало бы настройки и историю.
    private static func quit() -> Never {
        exit(EXIT_SUCCESS)
    }
}
