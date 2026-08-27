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

    nonisolated static let maxEntries = 200
    nonisolated static let maxItemCharacters = 100_000
    /// Спецификация §8.8: максимум на отдельный объект и общий бюджет.
    nonisolated static let maxObjectBytes = 100 * 1024 * 1024
    nonisolated static let totalByteBudget = 2 * 1024 * 1024 * 1024

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
        // То же при нечитаемой истории: метаданные не сохранятся, и blob
        // останется сиротой, которого sweep не подберёт.
        //
        // И то же при заблокированном экране: §8.9 запрещает трогать диск,
        // а save() всё равно откажется — blob лёг бы сиротой.
        guard keyIsPersistent, !isUnreadable, !screenLocked else { return }
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
        guard save() else {
            NSLog("Aza: metadata not saved — keeping %d blob(s)", removed.count)
            return
        }
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
        // Метаданные без этой записи должны быть на диске — иначе индекс
        // будет ссылаться на удалённое изображение.
        guard save() else { return }
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

    @discardableResult
    private func save() -> Bool {
        guard keyIsPersistent, !screenLocked, !isUnreadable else { return false }
        do {
            let payload = try JSONEncoder().encode(Payload(entries: entries))
            let sealed = try AES.GCM.seal(payload, using: key).combined!
            try sealed.write(to: storageURL, options: .atomic)
            return true
        } catch {
            NSLog("Aza: clipboard save failed (%@)", error.localizedDescription)
            return false
        }
    }

    private func load() {
        // Файла нет — обычный первый запуск, писать можно. А вот ошибка
        // ЧТЕНИЯ существующего файла (права, том отвалился) — не то же
        // самое: данные на месте, перезаписывать их нельзя.
        switch Self.fileState(at: storageURL) {
        case .absent:
            isUnreadable = false
            return
        case .unknown:
            // Проверить не удалось — считать это «первым запуском» нельзя:
            // следующая же запись затёрла бы существующую историю.
            isUnreadable = true
            NSLog("Aza: could not check whether the history exists; staying read-only")
            return
        case .present:
            break
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
            let backup = Self.unreadableBackupURL(for: storageURL)
            if !FileManager.default.fileExists(atPath: backup.path) {
                // Лог обязан отражать факт: раньше он рапортовал о копии,
                // даже когда copyItem падал.
                do {
                    try FileManager.default.copyItem(at: storageURL, to: backup)
                    NSLog("Aza: clipboard history could not be decrypted; kept intact, backup at %@",
                          backup.lastPathComponent)
                } catch {
                    NSLog("Aza: clipboard history could not be decrypted; kept intact, "
                          + "but the backup copy failed (%@)", error.localizedDescription)
                }
            }
            return
        }
        // Дошли сюда — файл расшифрован: прежний запрет на запись снят.
        isUnreadable = false
        entries = decoded.entries
        // Записи-изображения без blob-а бесполезны (например, ручное
        // удаление файлов) — выбрасываем, чтобы не показывать пустышки.
        // Выбрасываем запись, только если blob ТОЧНО отсутствует:
        // недоступный каталог не повод считать изображение потерянным и
        // вычёркивать его из истории насовсем.
        entries.removeAll {
            $0.resolvedKind == .image &&
            Self.fileState(at: blobURL(for: $0.id)) == .absent
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
        // «Файл не прочитался» и «файла нет» — РАЗНЫЕ вещи. Раньше обе
        // давали одну ветку, и временный сбой чтения приводил к записи
        // нового ключа поверх существующего: история становилась
        // нечитаемой навсегда. Отличаем по факту существования.
        let existingKey: SymmetricKey?
        do {
            let data = try Data(contentsOf: url)
            existingKey = data.count == 32 ? SymmetricKey(data: data) : nil
            if existingKey == nil {
                // Файл прочитался, но ключом не является. Ключа мы из него
                // не получим, однако и стирать его нельзя: это может быть
                // повреждённый настоящий ключ, единственная зацепка к
                // истории. Отодвигаем в сторону, а не переписываем — и
                // если отложить НЕ удалось, ничего не пишем вовсе.
                guard quarantineSpoiledKey(at: url) else {
                    return (SymmetricKey(size: .bits256), false)
                }
            }
        } catch {
            guard fileState(at: url) == .absent else {
                // Файл есть либо проверить не удалось. В обоих случаях
                // ничего не пишем: эфемерный ключ и запрет на запись
                // сохранят и историю, и ключ.
                NSLog("Aza: the debug key could not be read (%@) — "
                      + "history is read-only this session", error.localizedDescription)
                return (SymmetricKey(size: .bits256), false)
            }
            existingKey = nil
        }

        if let key = existingKey {
            guard historyState(for: key) != .opens else { return (key, true) }
            if let rescued = rescueKeyFromKeychain(into: url) { return (rescued, true) }
            return (key, true)
        }

        // Файла ключа нет. Прежде чем заводить новый (и обречь историю на
        // нечитаемость), пробуем спасти ключ из связки: сюда попадаем и
        // после релизной сборки, которая файл забрала себе и удалила.
        if let rescued = rescueKeyFromKeychain(into: url) { return (rescued, true) }

        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            NSLog("Aza: DEBUG build uses a file-based history key (no keychain prompts)")
            return (key, true)
        } catch {
            // Запись могла пройти, а права — нет: тогда на диске остался бы
            // открытый ключ с неизвестными правами.
            discardKeyFile(at: url)
            NSLog("Aza: could not create the debug key (%@)", error.localizedDescription)
            return (key, false)
        }
    }

    /// История, накопленная ДО перехода отладки на файловый ключ,
    /// зашифрована ключом из связки: без этой ветки файл цел, но для
    /// пользователя пуст.
    ///
    /// Связку трогаем не чаще одного раза на КОНКРЕТНУЮ историю: отпечаток
    /// файла, который спасти не удалось, запоминается, и следующий запуск
    /// в связку уже не лезет. Иначе отказ в доступе возвращал бы диалог
    /// «Разрешить всегда» при каждом старте — ровно то, от чего отладка и
    /// ушла на файловый ключ.
    private nonisolated static func rescueKeyFromKeychain(into url: URL) -> SymmetricKey? {
        let marker = url.deletingLastPathComponent()
            .appendingPathComponent("debug-history.rescue-failed")
        guard let fingerprint = historyFingerprint(),
              shouldAskKeychain(fingerprint: fingerprint, marker: marker) else { return nil }
        // Историю читаем ОДИН раз: между снятием отпечатка и проверкой
        // ключа файл мог стать нечитаемым, и тогда отметка «не подошёл»
        // была бы поставлена по несуществующему ответу.
        let stateBefore = historyState(for: SymmetricKey(size: .bits256))
        guard stateBefore == .doesNotOpen else {
            NSLog("Aza: the history changed while checking it — skipping the rescue")
            return nil
        }

        // Отметку «не спрашивать» ставим ТОЛЬКО по определённому ответу:
        // ключа в связке нет, или он есть и историю не открывает. Отказ в
        // доступе, отмена пользователем, временный сбой — не повод
        // запрещать спасение навсегда: правильный ключ никуда не делся.
        let lookup = keychainKeyLookup()
        guard case let .found(rescued) = lookup, historyState(for: rescued) == .opens else {
            guard lookup.isDefinitive else {
                NSLog("Aza: the keychain could not be read this time — will try again later")
                return nil
            }
            // Обращение к связке блокирующее: пока оно шло, история могла
            // измениться или стать нечитаемой. Отметка привязана к
            // ОТПЕЧАТКУ, поэтому ставим её только если отпечаток всё ещё
            // тот же — иначе запретили бы спасение для данных, которых
            // никто не проверял.
            guard historyFingerprint() == fingerprint else {
                NSLog("Aza: the history changed during the keychain call — no marker written")
                return nil
            }
            do {
                try fingerprint.write(to: marker, atomically: true, encoding: .utf8)
                NSLog("Aza: the keychain key does not open this history — not asking again")
            } catch {
                // Обещание «больше не спросим» держится на этом файле.
                // Если он не записался — так и говорим, а не молчим.
                NSLog("Aza: could not remember the failed rescue (%@) — the keychain "
                      + "dialog may return next launch", error.localizedDescription)
            }
            return nil
        }

        // Перед перезаписью убираем прежний ключ в сторону, если рядом
        // лежит копия нечитаемой истории: копия зашифрована ДРУГИМ
        // ключом, и вполне возможно, что именно тем, который сейчас в
        // этом файле. Перезапись «поверх» уничтожила бы его молча.
        // Сравнение намеренно через Optional: если прежний ключ не
        // прочитался, `current` равен nil, nil никогда не равен байтам
        // нового — и мы откладываем файл. Отказ чтения обязан вести к
        // сохранению, а не к тихой перезаписи.
        let currentKeyBytes = try? Data(contentsOf: url)
        if backupExists(), fileState(at: url) != .absent,
           currentKeyBytes != rescued.withUnsafeBytes({ Data($0) }) {
            guard quarantineSpoiledKey(at: url) else {
                NSLog("Aza: a backup exists and the old key could not be set aside — "
                      + "leaving everything as is, history is read-only this session")
                return nil
            }
        }

        // Ошибки записи НЕ глотаем: молча вернуть «спасено» значило бы
        // обещать, что связки больше не будет, и не выполнить обещание.
        do {
            try rescued.withUnsafeBytes { Data($0) }
                .write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: url.path)
            neutralizeMarker(marker)
            NSLog("Aza: recovered the clipboard history key from the keychain")
        } catch {
            discardKeyFile(at: url)
            NSLog("Aza: history key recovered but not stored (%@) — the keychain "
                  + "will be asked again next launch", error.localizedDescription)
        }
        return rescued
    }


    /// Спрашивать ли связку про эту историю. Нет — если про НЕЁ ЖЕ уже
    /// известно, что связка не помогает: повторный диалог при каждом
    /// запуске недопустим. Новая история (другой отпечаток) получает
    /// новую попытку.
    nonisolated static func shouldAskKeychain(fingerprint: String, marker: URL) -> Bool {
        guard let recorded = try? String(contentsOf: marker, encoding: .utf8) else { return true }
        return recorded.trimmingCharacters(in: .whitespacesAndNewlines) != fingerprint
    }

    /// Отпечаток файла истории: спасение относится именно к нему, а новая
    /// история должна получить новую попытку.
    private nonisolated static func historyFingerprint() -> String? {
        guard let data = try? Data(contentsOf: defaultStorageURL()), !data.isEmpty else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
#endif

    /// Убирает файл ключа: он лежит открытым, и оставлять его нельзя.
    ///
    /// Если удалить не выходит, затираем СОДЕРЖИМОЕ — ключ перестаёт
    /// читаться, даже когда сам файл остаётся. Это про логическое
    /// содержимое файла, а не про физические блоки: copy-on-write APFS,
    /// снимки и выравнивание износа SSD могут сохранить прежние байты, и
    /// обещать «стёрто с диска» мы не вправе.
    nonisolated static func discardKeyFile(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            return
        } catch let error as CocoaError where Self.meansNoSuchFile(error) {
            // Убирать нечего — и предупреждать не о чем. Проверять
            // существование заранее нельзя: fileExists не отличает
            // «файла нет» от «не удалось проверить».
            return
        } catch {
            NSLog("Aza: could not delete the key file (%@) — wiping its contents",
                  error.localizedDescription)
        }
        // Затираем ЧЕРЕЗ ОТКРЫТЫЙ ФАЙЛ, а не записью «поверх»: и удаление,
        // и атомарная запись требуют права на КАТАЛОГ (обе создают или
        // удаляют записи в нём). Если каталог недоступен на запись, оба
        // пути падают одинаково, а ключ остаётся лежать открытым — это
        // и показал тест. Усечение существующего файла каталога не
        // касается.
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data(repeating: 0, count: 64))
            try handle.truncate(atOffset: 0)
            // close() тоже может упасть (сброс на диск) — молчать об этом
            // нельзя: затирание могло не дойти до файла.
            try handle.close()
        } catch {
            NSLog("Aza: UNPROTECTED key file left at %@ (%@) — delete it by hand",
                  url.path, error.localizedDescription)
        }
    }

    private nonisolated static func keychainKey() -> (SymmetricKey, Bool) {
        let service = "com.tmmt.Aza.clipboard"
        let account = "history-key"
        let query: [String: Any] = [
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
            // Элемент неверной длины — не ключ: заменяем его как
            // отсутствующий, иначе сессия навсегда стала бы read-only.
            guard data.count == 32 else {
                // Прежде чем затирать, пробуем спасти: элемент мог просто
                // «поехать» — лишний байт по краям или base64. Годность
                // проверяем по факту, расшифровкой истории, поэтому
                // случайное совпадение практически исключено. Файл с
                // повреждённым ключом мы откладываем в сторону, и с
                // элементом связки поступать иначе было бы непоследовательно.
                switch salvagedKey(from: data) {
                case let .recovered(salvaged):
                    var repair = query
                    repair[kSecReturnData as String] = nil
                    let raw = salvaged.withUnsafeBytes { Data($0) }
                    let fixed = SecItemUpdate(repair as CFDictionary,
                                              [kSecValueData as String: raw] as CFDictionary)
                    // Лог по ФАКТУ: ключ восстановлен всегда, а вот
                    // починили ли мы связку — вопрос отдельный.
                    NSLog(fixed == errSecSuccess
                          ? "Aza: recovered the history key and repaired the keychain item"
                          : "Aza: recovered the history key but could not repair the keychain "
                            + "item (%d) — history is read-only this session", fixed)
                    guard fixed == errSecSuccess else { return (salvaged, false) }
                    // Дальше — та же уборка, что и на обычном пути: открытый
                    // ключ рядом с историей не нужен, а устаревшая отметка
                    // не должна запрещать будущее спасение.
                    disposeRedundantDebugKey(given: salvaged)
                    neutralizeMarker(debugKeyURL().deletingLastPathComponent()
                        .appendingPathComponent("debug-history.rescue-failed"))
                    return (salvaged, true)
                case .unverifiable:
                    // История есть, но подтвердить кандидата нечем: файл не
                    // читается либо не открылся ни один. Заменять байты
                    // нельзя — среди них может быть правильный ключ к
                    // повреждённому файлу. Сессия только на чтение.
                    NSLog("Aza: keychain item looks damaged and no candidate opened the "
                          + "history — leaving the bytes alone, history is read-only")
                    return (SymmetricKey(size: .bits256), false)
                case .hopeless:
                    break
                }
                NSLog("Aza: keychain item has an unexpected size — replacing it")
                // Файл ключа читаем ОДИН раз и им же оперируем. Раньше
                // было два чтения: сбой первого выбирал случайный ключ, а
                // успех второго удалял настоящий отладочный — вместе это
                // уничтожало единственный ключ к истории.
                let inherited = debugFileKey()
                let replacement = inherited ?? SymmetricKey(size: .bits256)
                let raw = replacement.withUnsafeBytes { Data($0) }
                var update = query
                update[kSecReturnData as String] = nil
                let updated = SecItemUpdate(update as CFDictionary,
                                            [kSecValueData as String: raw] as CFDictionary)
                if updated == errSecSuccess, inherited != nil {
                    // Здесь основание другое, чем у disposeRedundantDebugKey:
                    // те же байты уже лежат в связке, файл избыточен по
                    // построению, состояние истории ни при чём.
                    discardKeyFile(at: debugKeyURL())
                }
                return (replacement, updated == errSecSuccess)
            }
            let stored = SymmetricKey(data: data)
            // Ключ из связки может оказаться не тем, которым зашифрована
            // лежащая рядом история (например, остался от прежних опытов,
            // а история накоплена отладочной сборкой). Проверяем по факту
            // и, если он не подходит, а отладочный ключ подходит — берём
            // тот, что действительно открывает данные.
            if historyState(for: stored) == .doesNotOpen, let debugKey = debugFileKey(),
               historyState(for: debugKey) == .opens {
                let raw = debugKey.withUnsafeBytes { Data($0) }
                var replace = query
                replace[kSecReturnData as String] = nil
                if SecItemUpdate(replace as CFDictionary,
                                 [kSecValueData as String: raw] as CFDictionary) == errSecSuccess {
                    // Ключ перенесён в связку — файл избыточен по построению.
                    discardKeyFile(at: debugKeyURL())
                    NSLog("Aza: adopted the debug history key (the keychain key did not fit)")
                    return (debugKey, true)
                }
                return (debugKey, false)
            }
            // Отладочный файл рядом с историей — открытый ключ на диске, и
            // хранить его не нужно. Но удаляем ТОЛЬКО когда точно знаем,
            // что он ничего не открывает: при нечитаемом файле истории
            // «подходит ли ключ связки» неизвестно, и удаление отладочного
            // уничтожило бы единственный годный.
            disposeRedundantDebugKey(given: stored)
            return (stored, true)
        }
        guard readStatus == errSecItemNotFound else {
            NSLog("Aza: keychain read failed (%d) — history is read-only this session", readStatus)
            return (SymmetricKey(size: .bits256), false)
        }

        // Ключ из отладочной сборки переносим, если он есть: иначе вся
        // накопленная история станет нечитаемой при первом же переходе
        // на подписанную сборку.
        let inherited = debugFileKey()
        let key = inherited ?? SymmetricKey(size: .bits256)

        let status = addKeyItem(query: query, keyData: key.withUnsafeBytes { Data($0) })
        if status != errSecSuccess {
            NSLog("Aza: keychain SecItemAdd failed (%d) — history will not survive relaunch", status)
            return (key, false)
        }
        if inherited != nil {
            // Файл больше не нужен и хранить его рядом с историей опасно.
            discardKeyFile(at: debugKeyURL())
            NSLog("Aza: migrated the debug history key into the keychain")
        }
        return (key, true)
    }

    /// Ключ из связки, если он там уже есть. Ничего не создаёт и не
    /// меняет: это спасательная операция для чтения старой истории.
    /// Итог обращения к связке. Важно отличать «ответ получен» от «не
    /// смогли спросить»: на первом можно строить решение «больше не
    /// спрашивать», на втором — нельзя.
    nonisolated enum KeychainLookup {
        case found(SymmetricKey)
        /// Элемента нет или он не похож на ключ — ответ определённый.
        case missing
        /// Отказ, отмена, временный сбой — ответа нет.
        case unavailable(OSStatus)

        var isDefinitive: Bool {
            switch self {
            case .found, .missing: return true
            case .unavailable: return false
            }
        }
    }

    private nonisolated static func keychainKeyLookup() -> KeychainLookup {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.tmmt.Aza.clipboard",
            kSecAttrAccount as String: "history-key",
            kSecReturnData as String: true,
        ] as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, data.count == 32 else { return .missing }
            return .found(SymmetricKey(data: data))
        case errSecItemNotFound:
            return .missing
        default:
            return .unavailable(status)
        }
    }

    private nonisolated static func debugKeyURL() -> URL {
        defaultStorageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("debug-history.key")
    }

    /// Ключ отладочной сборки, если файл цел.
    private nonisolated static func debugFileKey() -> SymmetricKey? {
        guard let data = try? Data(contentsOf: debugKeyURL()), data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    /// Что этот ключ может сказать о лежащей на диске истории.
    ///
    /// Раньше это был Bool, и «истории нет» было неотличимо от «историю не
    /// удалось прочитать»: обе давали true. На этом строилось решение
    /// удалить файловый ключ — то есть временный сбой чтения приводил к
    /// уничтожению единственного годного ключа.
    nonisolated enum HistoryState {
        /// Истории нет — терять нечего.
        case absent
        /// Ключ открывает историю.
        case opens
        /// История есть, но этим ключом не открывается.
        case doesNotOpen
        /// Файл истории есть, но прочитать его не удалось. Ничего
        /// разрушительного на этом основании делать нельзя.
        case unreadable
    }

    nonisolated static func historyState(for key: SymmetricKey,
                                        at url: URL? = nil) -> HistoryState {
        let url = url ?? defaultStorageURL()
        switch fileState(at: url) {
        case .absent: return .absent
        // «Не смогли проверить» — не «нет файла».
        case .unknown: return .unreadable
        case .present: break
        }
        guard let sealed = try? Data(contentsOf: url) else { return .unreadable }
        guard !sealed.isEmpty else { return .absent }
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return .unreadable }
        return (try? AES.GCM.open(box, using: key)) != nil ? .opens : .doesNotOpen
    }

    /// Итог попытки достать настоящий ключ из испорченных байтов.
    nonisolated enum Salvage {
        /// Ключ найден и подтверждён расшифровкой истории.
        case recovered(SymmetricKey)
        /// Истории нет — терять нечего, байты можно заменять.
        case hopeless
        /// История есть, но подтвердить кандидата не удалось: файл не
        /// читается, либо не открылся ни один. Заменять байты нельзя.
        ///
        /// Именно «нельзя», а не «жаль»: AES-GCM не отличает неверный
        /// ключ от повреждённых данных, поэтому «ни один не подошёл» на
        /// существующей истории может означать испорченный файл при
        /// ПРАВИЛЬНОМ ключе. Удалить данные пользователь может сам и
        /// осознанно — в разделе приватности.
        case unverifiable
    }

    /// Пытается достать настоящий ключ из испорченных байтов.
    ///
    /// Проверяются два правдоподобных повреждения: лишние байты по краям
    /// (все 32-байтовые окна) и base64. Кандидат принимается ТОЛЬКО если
    /// он расшифровывает существующую историю — подтверждение даёт
    /// аутентификация AES-GCM, а не догадка.
    ///
    /// История читается ОДИН раз. Так снимаются сразу две беды: гонка
    /// (файл мог стать нечитаемым посреди перебора, и это выглядело бы
    /// как «ключ не подошёл») и до 67 обращений к диску на запуск.
    nonisolated static func salvagedKey(from data: Data,
                                        historyAt url: URL? = nil) -> Salvage {
        let historyURL = url ?? defaultStorageURL()
        // Рядом с историей может лежать резервная копия, снятая когда-то с
        // нечитаемого файла. Она зашифрована ТЕМ ЖЕ ключом, поэтому пока
        // копия существует, байты ключа неприкосновенны.
        let hasBackup = fileState(at: unreadableBackupURL(for: historyURL)) != .absent

        switch fileState(at: historyURL) {
        case .absent: return hasBackup ? .unverifiable : .hopeless
        case .unknown: return .unverifiable
        case .present: break
        }
        guard let sealed = try? Data(contentsOf: historyURL) else { return .unverifiable }
        // Пустой файл — тоже файл. Он мог остаться от неудачной записи,
        // и настоящие данные лежат в резервной копии. «Ничего не видно»
        // не равно «терять нечего».
        guard !sealed.isEmpty else { return hasBackup ? .unverifiable : .hopeless }
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return .unverifiable }

        // Ограничение по объёму — до любых преобразований: элемент связки
        // приходит извне, и разбирать мегабайты мы не обязаны.
        guard data.count <= 4096 else { return .unverifiable }

        var candidates: [Data] = []
        if data.count > 32, data.count <= 96 {
            for start in 0...(data.count - 32) {
                candidates.append(data.subdata(in: start..<(start + 32)))
            }
        }
        if let text = String(data: data, encoding: .utf8),
           let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           decoded.count == 32 {
            candidates.append(decoded)
        }
        for candidate in candidates {
            let key = SymmetricKey(data: candidate)
            if (try? AES.GCM.open(box, using: key)) != nil { return .recovered(key) }
        }
        return .unverifiable
    }

    /// Убирает открытый файл ключа, когда он заведомо не нужен: рабочий
    /// ключ уже открывает историю, либо истории нет вовсе.
    ///
    /// Одно выражение на все пути намеренно. Раньше проверка была
    /// продублирована, копии разошлись, и одна из них удаляла файл при
    /// НЕЧИТАЕМОЙ истории — ровно то, от чего это различение и заводилось.
    ///
    /// Резервная копия перекрывает ВСЁ. «Рабочий ключ открывает историю»
    /// ничего не говорит про копию: та зашифрована другим ключом, и им
    /// вполне может быть этот файл. Сценарий не выдуманный — хватает двух
    /// обычных запусков: на первом создаётся пустая история новым ключом,
    /// на втором он её открывает, и файл, открывавший копию, удаляется.
    private nonisolated static func disposeRedundantDebugKey(given working: SymmetricKey) {
        guard shouldDiscardKey(working: working, historyURL: defaultStorageURL()) else { return }
        discardKeyFile(at: debugKeyURL())
    }

    /// Само решение — отдельно от файловых действий и с явным путём:
    /// иначе его нельзя проверить тестом, не трогая настоящую историю
    /// пользователя.
    nonisolated static func shouldDiscardKey(working: SymmetricKey, historyURL: URL) -> Bool {
        // Копия перекрывает всё: она зашифрована ДРУГИМ ключом, и им
        // вполне может быть этот файл.
        guard fileState(at: unreadableBackupURL(for: historyURL)) == .absent else { return false }
        switch historyState(for: working, at: historyURL) {
        case .opens, .absent: return true
        case .doesNotOpen, .unreadable: return false
        }
    }

    /// Лежит ли рядом копия нечитаемой истории. `.unknown` считаем «лежит»:
    /// не смогли проверить — значит не трогаем.
    private nonisolated static func backupExists() -> Bool {
        fileState(at: unreadableBackupURL(for: defaultStorageURL())) != .absent
    }

    /// Имя копии выводится ОДНИМ способом на весь файл: разъехавшиеся
    /// формулы дали бы защиту, которая защищает не тот файл.
    nonisolated static func unreadableBackupURL(for history: URL) -> URL {
        history.deletingPathExtension().appendingPathExtension("unreadable.bin")
    }

    /// Откладывает в сторону файл, который лежит на месте ключа, но
    /// ключом не является. Возвращает false, если отложить не удалось —
    /// тогда вызывающий обязан НИЧЕГО не писать: возможно, это
    /// повреждённый настоящий ключ, единственная зацепка к истории.
    ///
    /// Второй обломок не затирает первый: к имени добавляется номер.
    private nonisolated static func quarantineSpoiledKey(at url: URL) -> Bool {
        for suffix in ["corrupt"] + (2...20).map({ "corrupt.\($0)" }) {
            let spoiled = url.appendingPathExtension(suffix)
            guard fileState(at: spoiled) == .absent else { continue }
            do {
                try FileManager.default.moveItem(at: url, to: spoiled)
                NSLog("Aza: the key file is not a key — kept aside as %@",
                      spoiled.lastPathComponent)
                return true
            } catch {
                NSLog("Aza: could not set the damaged key aside (%@) — "
                      + "leaving it untouched", error.localizedDescription)
                return false
            }
        }
        NSLog("Aza: too many damaged key files kept aside — leaving this one untouched")
        return false
    }

    /// Обезвреживает отметку «не спрашивать связку» после удачного
    /// спасения. Если удалить файл не вышло, затираем содержимое: пустая
    /// отметка не совпадёт ни с одним отпечатком и не запретит будущее
    /// спасение, если нынешний ключ когда-нибудь потеряется.
    private nonisolated static func neutralizeMarker(_ marker: URL) {
        if (try? FileManager.default.removeItem(at: marker)) != nil { return }
        guard fileState(at: marker) != .absent else { return }
        do {
            let handle = try FileHandle(forWritingTo: marker)
            try handle.truncate(atOffset: 0)
            try handle.close()
        } catch {
            NSLog("Aza: stale rescue marker left at %@ (%@) — it may block a future "
                  + "recovery", marker.lastPathComponent, error.localizedDescription)
        }
    }

    /// Есть ли файл. Именно ТРИ состояния: `fileExists` возвращает false и
    /// когда файла нет, и когда проверить не удалось, а решения об
    /// удалении ключей на такой ответ опирать нельзя.
    nonisolated enum FileState { case absent, present, unknown }

    /// «Файла нет» приходит ДВУМЯ разными кодами: fileNoSuchFile (4) и
    /// fileReadNoSuchFile (260). Принимаем оба для ЛЮБОЙ операции: какой
    /// код придёт откуда — не гарантировано, а ошибка в сторону «не смог
    /// проверить» делает историю доступной только для чтения на пустом
    /// месте (проверял только код 4 — на чистой установке буфер переставал
    /// сохранять).
    private nonisolated static func meansNoSuchFile(_ error: CocoaError) -> Bool {
        error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }

    nonisolated static func fileState(at url: URL) -> FileState {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return .present
        } catch let error as CocoaError where Self.meansNoSuchFile(error) {
            return .absent
        } catch {
            return .unknown
        }
    }

    /// Можно ли безопасно расстаться с этим ключом.
    ///
    /// Только когда терять нечего: истории нет И нет резервной копии
    /// нечитаемой истории. `doesNotOpen` сюда НЕ входит: AES-GCM не
    /// отличает «не тот ключ» от «данные повреждены», и на испорченном
    /// файле правильный ключ выглядел бы неподходящим.
    ///
    /// Проверка копии обязательна: без неё отсутствие основного файла
    /// разрешало удалить ключ, которым зашифрована лежащая рядом копия, —
    /// то есть единственный ключ к ней.
    private nonisolated static func isSafeToDiscard(_ key: SymmetricKey) -> Bool {
        guard historyState(for: key) == .absent else { return false }
        return !backupExists()
    }

    private nonisolated static func addKeyItem(query: [String: Any], keyData: Data) -> OSStatus {
        var add = query
        add[kSecReturnData as String] = nil
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecValueData as String] = keyData
        return SecItemAdd(add as CFDictionary, nil)
    }



}
