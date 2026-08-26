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
    /// Избранное: не удаляется автоочисткой по объёму. Опционально,
    /// чтобы старые зашифрованные хранилища декодировались без миграции.
    var isFavorite: Bool?
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

    /// Срок хранения в днях (спецификация §8.8): 1/7/30/365, 0 — бессрочно.
    static let retentionKey = "ClipboardRetentionDays"
    static var retentionDays: Int {
        (UserDefaults.standard.object(forKey: retentionKey) as? Int) ?? 30
    }

    @Published private(set) var entries: [ClipEntry] = []

    private let storageURL: URL
    private let instanceLimit: Int
    /// nil — брать срок из настройки; self-test передаёт свой.
    private let instanceRetentionDays: Int?
    private let key: SymmetricKey
    /// false — ключ эфемерный (Keychain недоступен): историю не пишем,
    /// чтобы не затереть файл, зашифрованный настоящим ключом.
    private let keyIsPersistent: Bool

    /// Сессия без доступа к настоящему ключу: изменения не переживут
    /// перезапуск. Показывается в меню.
    var isReadOnly: Bool { !keyIsPersistent }

    private struct Payload: Codable {
        var version = 1
        var entries: [ClipEntry]
    }

    // MARK: Инициализация

    /// - Parameters:
    ///   - storageURL: файл зашифрованного хранилища.
    ///   - maxEntries: локальный лимит для самопроверок и тестов;
    ///     в приложении используется статический `maxEntries`.
    init(storageURL: URL? = nil,
         maxEntries: Int = ClipboardStore.maxEntries,
         retentionDays: Int? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.instanceLimit = maxEntries
        self.instanceRetentionDays = retentionDays
        (key, keyIsPersistent) = Self.loadOrCreateKey()
        load()
        pruneExpired()
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
            pruneExpired()
            save()
            return
        }

        entries.insert(ClipEntry(
            id: UUID(), text: trimmed, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName
        ), at: 0)
        pruneExpired()
        pruneExcess()
        save()
    }

    /// Хранение по сроку (спецификация §8.8): старше срока — удаляется,
    /// избранное — никогда. Вызывается при старте и каждом добавлении;
    /// смена настройки применяется при следующем копировании/запуске.
    private func pruneExpired() {
        let days = instanceRetentionDays ?? Self.retentionDays
        guard days > 0 else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let before = entries.count
        entries.removeAll { $0.isFavorite != true && $0.createdAt < cutoff }
        if entries.count != before { save() }
    }

    /// Только для self-test: сдвигает дату записи в прошлое.
    func backdate(id: UUID, to date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].createdAt = date
        save()
    }

    /// Избранное переживает автоочистку по объёму (спецификация §8.6).
    /// Записи хранятся новые-сверху, поэтому удаляем с хвоста — самые старые.
    private func pruneExcess() {
        var index = entries.count - 1
        while entries.count > instanceLimit && index >= 0 {
            if entries[index].isFavorite != true {
                entries.remove(at: index)
            }
            index -= 1
        }
    }

    func toggleFavorite(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite = !(entries[index].isFavorite == true)
        save()
    }

    /// Запись, удалённая пользователем, — для «Отменить».
    struct Deleted {
        let entry: ClipEntry
    }

    /// Удаляет карточку; возвращает данные для отмены (спецификация §8.7).
    func delete(id: UUID) -> Deleted? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let deleted = Deleted(entry: entries.remove(at: index))
        save()
        return deleted
    }

    /// Возвращает удалённую запись на её хронологическое место: индекс по
    /// createdAt, а не сохранённый, — новые копирования за время «Отменить»
    /// не смещают точку вставки.
    func restore(_ deleted: Deleted) {
        let index = entries.firstIndex { $0.createdAt < deleted.entry.createdAt }
            ?? entries.count
        entries.insert(deleted.entry, at: index)
        save()
    }

    /// Очищает историю, сохраняя избранное (как обещает кнопка в меню).
    func clearAll() {
        entries.removeAll { $0.isFavorite != true }
        save()
    }

    // MARK: Шифрование и диск

    private func save() {
        guard keyIsPersistent else { return }
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

    /// Возвращает (ключ, persistent). Новый ключ создаётся ТОЛЬКО при
    /// errSecItemNotFound. Любая другая ошибка чтения (отказ в доступе после
    /// смены подписи бинарника и т.п.) — существующий ключ НЕ трогаем:
    /// удаление или перезапись делает старую историю нерасшифровываемой
    /// навсегда. Вместо этого сессия работает с эфемерным ключом, а save()
    /// отключён, чтобы не затереть файл истории.
    private static func loadOrCreateKey() -> (SymmetricKey, Bool) {
        let service = "com.tmmt.Aza.clipboard"
        let account = "history-key"
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var readQuery = query
        readQuery[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &item)
        if readStatus == errSecSuccess,
           let attributes = item as? [String: Any],
           let data = attributes[kSecValueData as String] as? Data {
            // Одноразовая миграция: метка отмечает, что элемент уже
            // пересоздан подписанным приложением.
            if attributes[kSecAttrLabel as String] as? String != Self.keyOwnershipLabel {
                guard reassignKeyOwnership(query: query, keyData: data) else {
                    return (SymmetricKey(data: data), false)
                }
            }
            return (SymmetricKey(data: data), true)
        }
        guard readStatus == errSecItemNotFound else {
            NSLog("Aza: keychain read failed (%d) — history is read-only this session", readStatus)
            return (SymmetricKey(size: .bits256), false)
        }

        let key = SymmetricKey(size: .bits256)
        let status = addKeyItem(query: query, keyData: key.withUnsafeBytes { Data($0) })
        if status != errSecSuccess {
            NSLog("Aza: keychain SecItemAdd failed (%d) — history will not survive relaunch", status)
            return (key, false)
        }
        return (key, true)
    }

    /// Метка мигрированного элемента: миграция выполняется один раз НА
    /// КОНФИГУРАЦИЮ. Метки Debug и Release различаются: иначе Release,
    /// встретив Debug-элемент (ACL «любое приложение»), пропустил бы
    /// миграцию и унаследовал слабый ACL. Смена конфигурации мигрирует
    /// элемент заново в правильную сторону (ключ сохраняется).
#if DEBUG
    private static let keyOwnershipLabel = "Aza clipboard key v3 (debug, open ACL)"
#else
    private static let keyOwnershipLabel = "Aza clipboard key v3"
#endif

    private static func addKeyItem(query: [String: Any], keyData: Data) -> OSStatus {
        var add = query
        add[kSecReturnData as String] = nil
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = keyOwnershipLabel
        add[kSecValueData as String] = keyData
#if DEBUG
        // Dev-сборки переподписываются при каждой пересборке, а self-signed
        // сертификат не даёт стабильного designated requirement — строгий
        // ACL вызывает диалог Keychain на КАЖДЫЙ новый бинарник и блокирует
        // старт в AzaApp.init. Debug-ключ создаётся с ACL «любое
        // приложение»: шифрование на диске и защита от кражи бэкапа
        // сохраняются, изоляция от локальных процессов того же пользователя
        // — нет. Release использует строгий ACL по умолчанию (Developer ID
        // даёт стабильную подпись, диалог не повторяется).
        if let access = anyApplicationAccess() {
            add[kSecAttrAccess as String] = access
        }
#endif
        return SecItemAdd(add as CFDictionary, nil)
    }

#if DEBUG
    /// SecAccess, разрешающий расшифровку любому приложению без диалога.
    private static func anyApplicationAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("Aza clipboard key" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        guard let aclList = SecAccessCopyMatchingACLList(
            access, kSecACLAuthorizationDecrypt
        ) as? [SecACL] else { return access }
        for acl in aclList {
            var appList: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &appList, &description, &promptSelector) == errSecSuccess
            else { continue }
            // applicationList = nil означает «доверять всем приложениям»;
            // селектор без флагов отключает запрос пароля.
            SecACLSetContents(acl, nil, description ?? "Aza" as CFString,
                              SecKeychainPromptSelector())
        }
        return access
    }
#endif

    /// Однократная миграция владельца ключа. Элемент, созданный неподписанной
    /// сборкой, требует подтверждения в диалоге Keychain у КАЖДОГО нового
    /// бинарника (ACL + partition list привязаны к создателю). Пересоздание
    /// элемента текущим подписанным приложением привязывает доступ к
    /// сертификату «Aza Development» — будущие пересборки читают бесшумно.
    /// Ключ уже в памяти, поэтому текущая сессия работает при любом исходе.
    /// Возврат false — пересоздание не удалось: вызывающий обязан перевести
    /// сессию в read-only, чтобы не плодить состояния, которые не переживут
    /// перезапуск.
    private static func reassignKeyOwnership(query: [String: Any], keyData: Data) -> Bool {
        // Проба записи ДО удаления старого элемента: если Keychain не
        // принимает новые записи, старый ключ остаётся нетронутым.
        var probeQuery = query
        probeQuery[kSecAttrAccount as String] = "history-key.migration-probe"
        var probeDelete = probeQuery
        probeDelete[kSecReturnData as String] = nil
        SecItemDelete(probeDelete as CFDictionary)
        guard addKeyItem(query: probeQuery, keyData: keyData) == errSecSuccess else {
            NSLog("Aza: migration probe add failed — keeping the original key item")
            return false
        }
        SecItemDelete(probeDelete as CFDictionary)

        var del = query
        del[kSecReturnData as String] = nil
        SecItemDelete(del as CFDictionary)
        let status = addKeyItem(query: query, keyData: keyData)
        if status != errSecSuccess {
            // Только что проверенная запись внезапно упала: пытаемся вернуть
            // исходный элемент, чтобы история пережила перезапуск.
            let restore = addKeyItem(query: query, keyData: keyData)
            NSLog("Aza: key migration add failed (%d), restore=%d", status,
                  restore == errSecSuccess ? 1 : 0)
            return restore == errSecSuccess
        }
        return true
    }

    // MARK: Самопроверка (Debug)

    /// Раундтрип шифрования на временном файле. Проверяет: запись читается
    /// обратно, на диске нет открытого текста, подменённый файл молча
    /// игнорируется, избранное переживает перезагрузку и автоочистку.
    static func runSelfTest(sample: String) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aza-clipboard-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let store = ClipboardStore(storageURL: tempURL, maxEntries: 3)
        store.add(text: sample, sourceAppBundleID: nil, sourceAppName: nil)
        assert(store.entries.first?.text == sample)

        // Избранное: пометка, перезагрузка, защита от автоочистки.
        store.toggleFavorite(id: store.entries[0].id)
        assert(store.entries[0].isFavorite == true)

        for suffix in ["а", "б", "в"] {
            store.add(text: sample + suffix,
                      sourceAppBundleID: nil, sourceAppName: nil)
        }
        assert(store.entries.count == 3)
        assert(store.entries.contains { $0.text == sample && $0.isFavorite == true },
               "избранное удалено автоочисткой")
        assert(store.entries.first?.text == sample + "в",
               "автоочистка удалила новейшую запись вместо старейшей")
        assert(!store.entries.contains { $0.text == sample + "а" },
               "автоочистка не удалила старейшую запись")

        let rawOnDisk = (try? Data(contentsOf: tempURL)) ?? Data()
        assert(!rawOnDisk.isEmpty)
        assert(rawOnDisk.range(of: Data(sample.utf8)) == nil, "plaintext leaked to disk")

        let reloaded = ClipboardStore(storageURL: tempURL, maxEntries: 3)
        assert(reloaded.entries.first { $0.text == sample }?.isFavorite == true,
               "избранное потеряно при перезагрузке")
        assert(reloaded.entries.count == 3)

        // Удаление с отменой: запись возвращается на хронологическое место
        // даже после нового копирования между delete и restore.
        let victim = reloaded.entries[1]
        let deleted = reloaded.delete(id: victim.id)
        assert(deleted != nil && !reloaded.entries.contains { $0.id == victim.id })
        reloaded.add(text: sample + "г", sourceAppBundleID: nil, sourceAppName: nil)
        reloaded.restore(deleted!)
        assert(reloaded.entries[2].id == victim.id,
               "отмена удаления не вернула запись на хронологическое место")

        reloaded.clearAll()
        assert(reloaded.entries.map(\.text) == [sample],
               "clearAll обязан сохранить избранное и удалить остальное")

        // Хранение по сроку: просроченное удаляется, избранное — нет.
        let aged = ClipboardStore(storageURL: tempURL, maxEntries: 3, retentionDays: 7)
        aged.add(text: sample + "старое", sourceAppBundleID: nil, sourceAppName: nil)
        aged.backdate(id: aged.entries[0].id, to: Date().addingTimeInterval(-8 * 86_400))
        let agedReload = ClipboardStore(storageURL: tempURL, maxEntries: 3, retentionDays: 7)
        assert(!agedReload.entries.contains { $0.text == sample + "старое" },
               "просроченная запись не удалена")
        assert(agedReload.entries.contains { $0.text == sample && $0.isFavorite == true },
               "избранное не должно устаревать")

        try? Data([0x00, 0x01, 0x02]).write(to: tempURL)
        assert(ClipboardStore(storageURL: tempURL, maxEntries: 3).entries.isEmpty)
    }
}
