import Combine
import CryptoKit
import Foundation

/// Одна запись истории буфера обмена. Все новые поля опциональны, чтобы
/// старые зашифрованные хранилища декодировались без миграции.
struct ClipEntry: Codable, Equatable, Identifiable {
    /// Вид записи; nil в хранилище означает обычный текст.
    enum Kind: String, Codable {
        case text, rtf, image, files, link
    }

    let id: UUID
    /// Универсальная строка отображения и поиска: для файлов — имена,
    /// для изображения — подпись, для ссылки — URL.
    var text: String
    var createdAt: Date
    /// Bundle ID приложения-источника, если удалось определить.
    var sourceAppBundleID: String?
    /// Локализованное имя приложения-источника.
    var sourceAppName: String?
    /// Избранное: не удаляется автоочисткой по объёму и сроку.
    var isFavorite: Bool?
    var kind: Kind?
    /// RTF хранится инлайн — он мал; изображение живёт в отдельном
    /// зашифрованном blob-файле по имени id (см. blobURL).
    var rtfData: Data?
    /// Пути файлов; содержимое файлов никогда не копируется.
    var filePaths: [String]?
    /// Фактические байты на диске (для бюджета 2 ГБ).
    var byteSize: Int?
    /// SHA-256 содержимого — дедупликация изображений и RTF.
    var contentHash: String?
    /// Маленькое PNG-превью (≤48px, единицы КБ) — инлайн в зашифрованном
    /// payload, чтобы карточки не расшифровывали blob при каждой отрисовке.
    var thumbnailData: Data?

    var resolvedKind: Kind { kind ?? .text }
}

/// Хранилище истории буфера: AES-GCM (CryptoKit) на диске, ключ —
/// в Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly). Файл —
/// Application Support/Aza/clipboard-history.bin.
///
@MainActor
final class ClipboardStore: ObservableObject {

    static let maxEntries = 200
    static let maxItemCharacters = 100_000
    /// Спецификация §8.8: максимум на отдельный объект и общий бюджет.
    static let maxObjectBytes = 100 * 1024 * 1024
    static let totalByteBudget = 2 * 1024 * 1024 * 1024

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

    /// На диске лежит история, которую этот ключ не расшифровывает.
    /// Пока флаг поднят, писать в файл запрещено — иначе чужие данные
    /// будут стёрты безвозвратно.
    private(set) var isUnreadable = false

    /// Сессия без доступа к настоящему ключу или к существующей истории:
    /// изменения не переживут перезапуск. Показывается в меню.
    var isReadOnly: Bool { !keyIsPersistent || isUnreadable }

    /// Экран заблокирован (спецификация §8.9): расшифрованная история
    /// выгружена из памяти, save() не пишет — случайная мутация в этом
    /// окне не может затереть файл пустым массивом.
    private(set) var screenLocked = false

    /// Блокировка Mac: выгрузить расшифрованное из памяти, диск не трогать.
    func wipeInMemory() {
        screenLocked = true
        entries = []
    }

    /// Разблокировка: перечитать историю с диска.
    func reloadFromDisk() {
        screenLocked = false
        load()
    }

    private struct Payload: Codable {
        var version = 1
        var entries: [ClipEntry]
    }

    // MARK: Инициализация

    /// - Parameters:
    ///   - storageURL: файл зашифрованного хранилища.
    ///   - maxEntries: локальный лимит для тестов;
    ///     в приложении используется статический `maxEntries`.
    private let instanceByteBudget: Int

    /// Синхронный init: получает ключ прямо здесь. Keychain-диалог
    /// заблокирует вызвавший поток — приложение этот путь не использует.
    /// Приложение создаёт хранилище через init(preparedKey:) после
    /// фонового obtainKey().
    convenience init(storageURL: URL? = nil,
                     maxEntries: Int = ClipboardStore.maxEntries,
                     retentionDays: Int? = nil,
                     byteBudget: Int = ClipboardStore.totalByteBudget) {
        self.init(preparedKey: Self.obtainKey(),
                  storageURL: storageURL, maxEntries: maxEntries,
                  retentionDays: retentionDays, byteBudget: byteBudget)
    }

    init(preparedKey: (key: SymmetricKey, persistent: Bool),
         storageURL: URL? = nil,
         maxEntries: Int = ClipboardStore.maxEntries,
         retentionDays: Int? = nil,
         byteBudget: Int = ClipboardStore.totalByteBudget) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.instanceLimit = maxEntries
        self.instanceRetentionDays = retentionDays
        self.instanceByteBudget = byteBudget
        (key, keyIsPersistent) = preparedKey
        load()
        commit(removingBlobsOf: pruneExpired())
    }

    /// Каталог blob-файлов (зашифрованные изображения): сосед файла
    /// хранилища, чтобы self-test с временным файлом был изолирован.
    private var blobsDirectory: URL {
        storageURL.deletingPathExtension().appendingPathExtension("blobs")
    }

    private func blobURL(for id: UUID) -> URL {
        blobsDirectory.appendingPathComponent(id.uuidString + ".bin")
    }

    nonisolated static func defaultStorageURL() -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aza", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("clipboard-history.bin")
    }

    // MARK: Публичный API

    /// Дедупликация: совпадение по виду и ключу поднимает запись наверх.
    /// Возврат true — дубликат обработан, добавлять не нужно.
    private func dedup(where match: (ClipEntry) -> Bool) -> Bool {
        guard let index = entries.firstIndex(where: match) else { return false }
        var moved = entries.remove(at: index)
        moved.createdAt = Date()
        entries.insert(moved, at: 0)
        commit(removingBlobsOf: pruneExpired())
        return true
    }

    /// Общий финал добавления: вставка сверху, очистки, запись, blob-ы
    /// удалённых записей стираются ПОСЛЕ сохранения метаданных.
    private func insertNew(_ entry: ClipEntry) {
        entries.insert(entry, at: 0)
        var removed = pruneExpired()
        removed += pruneExcess()
        commit(removingBlobsOf: removed)
    }

    /// Добавляет текстовую запись (повторное копирование поднимает наверх).
    func add(text: String, sourceAppBundleID: String?, sourceAppName: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.maxItemCharacters else { return }
        if dedup(where: { $0.resolvedKind == .text && $0.text == trimmed }) { return }
        insertNew(ClipEntry(
            id: UUID(), text: trimmed, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            byteSize: trimmed.utf8.count
        ))
    }

    /// Ссылка (не file://): текст = URL, отдельный вид для карточки.
    func addLink(_ url: URL, sourceAppBundleID: String?, sourceAppName: String?) {
        let text = url.absoluteString
        guard !text.isEmpty, text.count <= Self.maxItemCharacters else { return }
        if dedup(where: { $0.resolvedKind == .link && $0.text == text }) { return }
        insertNew(ClipEntry(
            id: UUID(), text: text, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .link, byteSize: text.utf8.count
        ))
    }

    /// RTF: инлайн-данные + плоский текст для показа и поиска.
    /// Дедупликация по хешу данных — по тексту терялось форматирование.
    func addRTF(text: String, rtf: Data,
                sourceAppBundleID: String?, sourceAppName: String?) {
        guard rtf.count <= Self.maxObjectBytes else { return }
        let display = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !display.isEmpty, display.count <= Self.maxItemCharacters else { return }
        let hash = Self.sha256(rtf)
        if dedup(where: { $0.resolvedKind == .rtf && $0.contentHash == hash }) { return }
        insertNew(ClipEntry(
            id: UUID(), text: display, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .rtf, rtfData: rtf, byteSize: rtf.count + display.utf8.count,
            contentHash: hash
        ))
    }

    /// Изображение (нормализованный PNG). Данные — в отдельном
    /// зашифрованном blob-файле; в метаданных только подпись и хеш.
    /// Blob пишется ДО метаданных: неудача записи не создаёт запись.
    func addImage(png: Data, label: String, thumbnail: Data?,
                  sourceAppBundleID: String?, sourceAppName: String?) {
        // Read-only-сессия не пишет blob-ы: эфемерный ключ сделает файл
        // нечитаемым, а до следующего успешного запуска копились бы сироты.
        guard keyIsPersistent else { return }
        guard png.count <= Self.maxObjectBytes else { return }
        let hash = Self.sha256(png)
        if dedup(where: { $0.resolvedKind == .image && $0.contentHash == hash }) { return }
        let id = UUID()
        guard let sealedSize = writeBlob(png, for: id) else { return }
        insertNew(ClipEntry(
            id: id, text: label, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .image, byteSize: sealedSize + (thumbnail?.count ?? 0),
            contentHash: hash, thumbnailData: thumbnail
        ))
    }

    /// Файлы: только пути, содержимое не копируется (спецификация).
    func addFiles(paths: [String], sourceAppBundleID: String?, sourceAppName: String?) {
        guard !paths.isEmpty else { return }
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        if dedup(where: { $0.resolvedKind == .files && $0.filePaths == paths }) { return }
        insertNew(ClipEntry(
            id: UUID(), text: names, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .files, filePaths: paths,
            byteSize: paths.reduce(0) { $0 + $1.utf8.count }
        ))
    }

    /// Копирование карточки обратно в буфер: поднять наверх без
    /// переклассификации содержимого.
    func touch(id: UUID) {
        _ = dedup(where: { $0.id == id })
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Хранение по сроку (спецификация §8.8): старше срока — удаляется,
    /// избранное — никогда. Возвращает удалённые записи (их blob-ы
    /// стирает commit после сохранения метаданных).
    @discardableResult
    private func pruneExpired() -> [ClipEntry] {
        let days = instanceRetentionDays ?? Self.retentionDays
        guard days > 0 else { return [] }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let removed = entries.filter { $0.isFavorite != true && $0.createdAt < cutoff }
        guard !removed.isEmpty else { return [] }
        entries.removeAll { $0.isFavorite != true && $0.createdAt < cutoff }
        return removed
    }

    /// Только для тестов: сдвигает дату записи в прошлое.
    func backdate(id: UUID, to date: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].createdAt = date
        save()
    }

    /// Избранное переживает автоочистку по объёму (спецификация §8.6).
    /// Записи хранятся новые-сверху, поэтому удаляем с хвоста — самые
    /// старые. Два лимита: число записей и общий бюджет байтов (§8.8);
    /// избранное делает бюджет мягким потолком — спецификация освобождает
    /// его от очистки.
    @discardableResult
    private func pruneExcess() -> [ClipEntry] {
        var removed: [ClipEntry] = []
        var index = entries.count - 1
        while entries.count > instanceLimit && index >= 0 {
            if entries[index].isFavorite != true {
                removed.append(entries.remove(at: index))
            }
            index -= 1
        }
        var total = entries.reduce(0) { $0 + ($1.byteSize ?? $1.text.utf8.count) }
        index = entries.count - 1
        while total > instanceByteBudget && index >= 0 {
            let entry = entries[index]
            if entry.isFavorite != true {
                total -= entry.byteSize ?? entry.text.utf8.count
                removed.append(entries.remove(at: index))
            }
            index -= 1
        }
        return removed
    }

    /// Сохраняет метаданные и лишь затем стирает blob-ы удалённых записей:
    /// при сбое записи хуже потерять немного места, чем данные.
    /// В read-only-сессии (эфемерный ключ) blob-ы НЕ трогаем: метаданные
    /// не сохраняются, и удаление стёрло бы изображения настоящей истории.
    private func commit(removingBlobsOf removed: [ClipEntry]) {
        save()
        guard keyIsPersistent else { return }
        for entry in removed where entry.resolvedKind == .image {
            try? FileManager.default.removeItem(at: blobURL(for: entry.id))
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
    /// Blob изображения НЕ удаляется — он нужен все пять секунд окна
    /// «Отменить»; окончательно его стирает finalizeDelete.
    func delete(id: UUID) -> Deleted? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let deleted = Deleted(entry: entries.remove(at: index))
        save()
        return deleted
    }

    /// Завершает удаление после истечения окна «Отменить» (или замены его
    /// новым удалением). Если запись успели восстановить — blob остаётся.
    /// Read-only-сессия blob-ы не трогает (см. commit). Под блокировкой
    /// экрана диск не мутируется вовсе (§8.9) — неудалённый blob подберёт
    /// sweep сирот при следующем запуске.
    func finalizeDelete(_ deleted: Deleted) {
        guard keyIsPersistent, !screenLocked else { return }
        guard !entries.contains(where: { $0.id == deleted.entry.id }) else { return }
        if deleted.entry.resolvedKind == .image {
            try? FileManager.default.removeItem(at: blobURL(for: deleted.entry.id))
        }
    }

    /// Массовое удаление найденного (спецификация §8.7): избранное
    /// пропускается. Возвращает пакет для общей кнопки «Отменить».
    func deleteBatch(ids: [UUID]) -> [Deleted] {
        var batch: [Deleted] = []
        for id in ids {
            guard let index = entries.firstIndex(where: { $0.id == id }),
                  entries[index].isFavorite != true else { continue }
            batch.append(Deleted(entry: entries.remove(at: index)))
        }
        if !batch.isEmpty { save() }
        return batch
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
        let removed = entries.filter { $0.isFavorite != true }
        entries.removeAll { $0.isFavorite != true }
        commit(removingBlobsOf: removed)
    }

    // MARK: Blob-файлы изображений

    /// Пишет зашифрованный blob; возвращает размер на диске или nil.
    private func writeBlob(_ data: Data, for id: UUID) -> Int? {
        do {
            try FileManager.default.createDirectory(at: blobsDirectory,
                                                    withIntermediateDirectories: true)
            let sealed = try AES.GCM.seal(data, using: key).combined!
            try sealed.write(to: blobURL(for: id), options: .atomic)
            return sealed.count
        } catch {
            NSLog("Aza: blob write failed (%@)", error.localizedDescription)
            return nil
        }
    }

    /// Расшифрованное изображение записи (для вставки в буфер).
    func imageData(for entry: ClipEntry) -> Data? {
        guard entry.resolvedKind == .image,
              let sealedData = try? Data(contentsOf: blobURL(for: entry.id)),
              let box = try? AES.GCM.SealedBox(combined: sealedData),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return data
    }

    /// Удаляет blob-ы без записей. Вызывается ТОЛЬКО после успешной
    /// расшифровки хранилища: при сбое загрузки или недоступном ключе
    /// blob-ы не трогаем — их записи могут вернуться.
    private func sweepOrphanBlobs() {
        guard keyIsPersistent else { return }
        let valid = Set(entries.filter { $0.resolvedKind == .image }
            .map { $0.id.uuidString + ".bin" })
        let files = (try? FileManager.default
            .contentsOfDirectory(atPath: blobsDirectory.path)) ?? []
        for file in files where !valid.contains(file) {
            try? FileManager.default.removeItem(
                at: blobsDirectory.appendingPathComponent(file))
        }
    }

    // MARK: Шифрование и диск

    private func save() {
        guard keyIsPersistent, !screenLocked, !isUnreadable else { return }
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
        // Файла нет — обычный первый запуск, писать можно. А вот ошибка
        // ЧТЕНИЯ существующего файла (права, том отвалился) — не то же
        // самое: данные на месте, перезаписывать их нельзя.
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            isUnreadable = false
            return
        }
        guard let sealedData = try? Data(contentsOf: storageURL) else {
            isUnreadable = true
            NSLog("Aza: clipboard history exists but cannot be read; staying read-only")
            return
        }
        guard !sealedData.isEmpty else {
            isUnreadable = false
            return
        }

        guard let box = try? AES.GCM.SealedBox(combined: sealedData),
              let payload = try? AES.GCM.open(box, using: key),
              let decoded = try? JSONDecoder().decode(Payload.self, from: payload) else {
            // Файл ЕСТЬ, но не читается этим ключом (ключ пересоздан,
            // повреждение). Данные пользователя всё ещё в нём: писать
            // поверх нельзя — иначе первое же копирование сотрёт историю
            // навсегда. Уходим в read-only и откладываем копию файла.
            isUnreadable = true
            // Одна копия на хранилище, а не на каждую попытку загрузки:
            // разблокировки экрана перезапускают load() и наплодили бы
            // бесконечные бэкапы.
            let backup = storageURL.deletingPathExtension()
                .appendingPathExtension("unreadable.bin")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.copyItem(at: storageURL, to: backup)
                NSLog("Aza: clipboard history could not be decrypted; kept intact, backup at %@",
                      backup.lastPathComponent)
            }
            return
        }
        // Дошли сюда — файл расшифрован: прежний запрет на запись снят.
        isUnreadable = false
        entries = decoded.entries
        // Записи-изображения без blob-а бесполезны (например, ручное
        // удаление файлов) — выбрасываем, чтобы не показывать пустышки.
        entries.removeAll {
            $0.resolvedKind == .image &&
            !FileManager.default.fileExists(atPath: blobURL(for: $0.id).path)
        }
        sweepOrphanBlobs()
    }

    // MARK: Ключ в Keychain

    /// Возвращает (ключ, persistent). Новый ключ создаётся ТОЛЬКО при
    /// errSecItemNotFound. Любая другая ошибка чтения (отказ в доступе после
    /// смены подписи бинарника и т.п.) — существующий ключ НЕ трогаем:
    /// удаление или перезапись делает старую историю нерасшифровываемой
    /// навсегда. Вместо этого сессия работает с эфемерным ключом, а save()
    /// отключён, чтобы не затереть файл истории.
    /// Вызывается С ФОНОВОГО потока (AzaApp.Startup): SecItemCopyMatching
    /// может показать модальный диалог Keychain (разблокировка связки,
    /// подтверждение доступа) — на главном потоке он вешал всё приложение,
    /// включая коррекцию раскладки.
    nonisolated static func obtainKey() -> (SymmetricKey, Bool) {
        loadOrCreateKey()
    }

    private nonisolated static func loadOrCreateKey() -> (SymmetricKey, Bool) {
#if DEBUG
        // ACL связки ключей привязан к хэшу КОНКРЕТНОГО бинарника, а не к
        // сертификату, поэтому каждая пересборка для системы — новая
        // программа: диалог «Разрешить всегда» возвращался после каждой
        // сборки, а отказ или сбой чтения оборачивался потерей истории.
        // В отладке ключ лежит файлом 0600 рядом с историей: шифрование
        // на машине разработчика становится формальным, зато данные и
        // рабочий процесс целы. В Release — по-прежнему Keychain.
        return developmentKey()
#else
        return keychainKey()
#endif
    }

#if DEBUG
    private nonisolated static func developmentKey() -> (SymmetricKey, Bool) {
        let url = defaultStorageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("debug-history.key")
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return (SymmetricKey(data: data), true)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            NSLog("Aza: DEBUG build uses a file-based history key (no keychain prompts)")
            return (key, true)
        } catch {
            NSLog("Aza: could not create the debug key (%@)", error.localizedDescription)
            return (key, false)
        }
    }
#endif

    private nonisolated static func keychainKey() -> (SymmetricKey, Bool) {
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

    private nonisolated static func addKeyItem(query: [String: Any], keyData: Data) -> OSStatus {
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
    private nonisolated static func anyApplicationAccess() -> SecAccess? {
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
    private nonisolated static func reassignKeyOwnership(query: [String: Any], keyData: Data) -> Bool {
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

}
