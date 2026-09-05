import Combine
import CryptoKit
import Darwin
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
    /// Транскрипт диктовки: живёт во вкладке «Диктовка», не в истории.
    var isTranscript: Bool?
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
/// в локальном файле 0600, общем для Debug и Release. История —
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
    /// false — локальный ключ недоступен: историю не пишем,
    /// чтобы не затереть файл, зашифрованный настоящим ключом.
    private let keyIsPersistent: Bool

    /// На диске лежит история, которую этот ключ не расшифровывает.
    /// Пока флаг поднят, писать в файл запрещено — иначе чужие данные
    /// будут стёрты безвозвратно.
    private(set) var isUnreadable = false

    /// Последняя ФАКТИЧЕСКАЯ запись на диск провалилась (диск полон, права):
    /// мутация осталась только в памяти. Отдельно от isReadOnly — тот про
    /// ключ и нечитаемость; transient-IO раньше молчал, и UI рапортовал
    /// «удалено»/«в избранном», хотя диск не изменился.
    @Published private(set) var lastSaveFailed = false

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
        // Сокращение срока хранения действует сразу, а не при следующей
        // записи в буфер: пользователь ждёт, что старое исчезло.
        // Слушаем все изменения defaults: фильтр по ≤200 записям дёшев,
        // диск трогается только когда что-то реально истекло.
        retentionObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            azaAssumeMainUnchecked {
                guard let self, !Self.maintenanceSuspended else { return }
                let removed = self.pruneExpired()
                if !removed.isEmpty { self.commit(removingBlobsOf: removed) }
            }
        }
    }

    private var retentionObserver: (any NSObjectProtocol)?

    /// PrivacyCleanup поднимает флаг перед удалением данных: сброс defaults
    /// (removePersistentDomain) синхронно будит наблюдателя выше, и commit
    /// записал бы историю ЗАНОВО — уже после удаления файла и ключа.
    static var maintenanceSuspended = false

    deinit {
        if let retentionObserver {
            NotificationCenter.default.removeObserver(retentionObserver)
        }
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
    private func dedup(where match: (ClipEntry) -> Bool,
                       at copiedAt: Date = Date(),
                       sourceAppBundleID: String?,
                       sourceAppName: String?,
                       update: (inout ClipEntry) -> Void = { _ in }) -> Bool {
        guard !screenLocked else { return true }
        guard let index = entries.firstIndex(where: match) else { return false }
        var moved = entries.remove(at: index)
        // Метка только растёт, а атрибуция следует за НОВЕЙШИМ событием:
        // повторная копия из другого приложения перевешивает источник на
        // себя; запоздавший персист (диктовка, +250 мс), оказавшийся
        // старее свежей записи, не отматывает её и не трогает источник.
        if copiedAt >= moved.createdAt {
            moved.createdAt = copiedAt
            moved.sourceAppBundleID = sourceAppBundleID
            moved.sourceAppName = sourceAppName
        }
        update(&moved)
        insert(moved)
        commit(removingBlobsOf: pruneExpired())
        return true
    }

    /// Вставка по месту в хронологии (список — от новых к старым): картинка
    /// добавляется ПОСЛЕ фонового декодирования и с меткой момента копии
    /// обязана встать под текст, скопированный позже неё.
    private func insert(_ entry: ClipEntry) {
        let index = entries.firstIndex { $0.createdAt <= entry.createdAt } ?? entries.count
        entries.insert(entry, at: index)
    }

    /// Общий финал добавления: вставка по хронологии, очистки, запись,
    /// blob-ы удалённых записей стираются ПОСЛЕ сохранения метаданных.
    private func insertNew(_ entry: ClipEntry) {
        guard !screenLocked else { return }
        insert(entry)
        var removed = pruneExpired()
        removed += pruneExcess()
        commit(removingBlobsOf: removed)
    }

    /// Добавляет текстовую запись (повторное копирование поднимает наверх).
    /// Текст хранится КАК СКОПИРОВАН: обрезка пробелов/переводов строки
    /// меняла бы вставляемое (отступы кода). Трим — только для проверки
    /// «не пусто». `copiedAt` — момент копирования, если запись
    /// добавляется отложенно (диктовка персистится через 250 мс).
    func add(text: String, sourceAppBundleID: String?, sourceAppName: String?,
             copiedAt: Date = Date(), isTranscript: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, text.count <= Self.maxItemCharacters else { return }
        // Повторная диктовка того же текста помечает существующую запись
        // транскриптом; обратный дедуп (пользователь скопировал текст,
        // равный транскрипту) флаг не снимает — запись остаётся во вкладке.
        if dedup(where: { $0.resolvedKind == .text && $0.text == text },
                 at: copiedAt,
                 sourceAppBundleID: sourceAppBundleID,
                 sourceAppName: sourceAppName,
                 update: { if isTranscript { $0.isTranscript = true } }) { return }
        insertNew(ClipEntry(
            id: UUID(), text: text, createdAt: copiedAt,
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            isTranscript: isTranscript ? true : nil,
            byteSize: text.utf8.count
        ))
    }

    /// Ссылка (не file://): текст = URL, отдельный вид для карточки.
    func addLink(_ url: URL, sourceAppBundleID: String?, sourceAppName: String?) {
        let text = url.absoluteString
        guard !text.isEmpty, text.count <= Self.maxItemCharacters else { return }
        if dedup(where: { $0.resolvedKind == .link && $0.text == text },
                 sourceAppBundleID: sourceAppBundleID,
                 sourceAppName: sourceAppName) { return }
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
        guard !display.isEmpty, text.count <= Self.maxItemCharacters else { return }
        let hash = Self.sha256(rtf)
        if dedup(where: { $0.resolvedKind == .rtf && $0.contentHash == hash },
                 sourceAppBundleID: sourceAppBundleID,
                 sourceAppName: sourceAppName) { return }
        insertNew(ClipEntry(
            id: UUID(), text: text, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .rtf, rtfData: rtf, byteSize: rtf.count + text.utf8.count,
            contentHash: hash
        ))
    }

    /// Изображение (нормализованный PNG). Данные — в отдельном
    /// зашифрованном blob-файле; в метаданных только подпись и хеш.
    /// Blob пишется ДО метаданных: неудача записи не создаёт запись.
    /// `copiedAt` — момент копирования: декодирование идёт в фоне, и без
    /// метки картинка вставала бы в историю ПОЗЖЕ текста, скопированного
    /// после неё (список сортируется по createdAt).
    func addImage(png: Data, label: String, thumbnail: Data?,
                  sourceAppBundleID: String?, sourceAppName: String?,
                  copiedAt: Date = Date()) {
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
        // Повтор того же изображения освежает миниатюру: у старых записей
        // она могла быть сгенерирована в прежнем маленьком размере.
        if dedup(where: { $0.resolvedKind == .image && $0.contentHash == hash },
                 at: copiedAt,
                 sourceAppBundleID: sourceAppBundleID,
                 sourceAppName: sourceAppName,
                 update: { if let thumbnail { $0.thumbnailData = thumbnail } }) { return }
        let id = UUID()
        guard let sealedSize = writeBlob(png, for: id) else { return }
        insertNew(ClipEntry(
            id: id, text: label, createdAt: copiedAt,
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .image, byteSize: sealedSize + (thumbnail?.count ?? 0),
            contentHash: hash, thumbnailData: thumbnail
        ))
    }

    /// Файлы: только пути, содержимое не копируется (спецификация).
    func addFiles(paths: [String], sourceAppBundleID: String?, sourceAppName: String?) {
        guard !paths.isEmpty else { return }
        let names = paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        if dedup(where: { $0.resolvedKind == .files && $0.filePaths == paths },
                 sourceAppBundleID: sourceAppBundleID,
                 sourceAppName: sourceAppName) { return }
        insertNew(ClipEntry(
            id: UUID(), text: names, createdAt: Date(),
            sourceAppBundleID: sourceAppBundleID, sourceAppName: sourceAppName,
            kind: .files, filePaths: paths,
            byteSize: paths.reduce(0) { $0 + $1.utf8.count }
        ))
    }

    /// Копирование карточки обратно в буфер: поднять наверх без
    /// переклассификации. Атрибуция остаётся исходной — карточка
    /// показывает, ОТКУДА содержимое пришло, а не кто его переиспользовал.
    func touch(id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        _ = dedup(where: { $0.id == id },
                  sourceAppBundleID: entry.sourceAppBundleID,
                  sourceAppName: entry.sourceAppName)
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
        guard !screenLocked else { return }
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
        // См. save(): во время удаления данных диск не трогаем.
        guard !Self.maintenanceSuspended else { return nil }
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
        guard !screenLocked, entry.resolvedKind == .image,
              let sealedData = try? Data(contentsOf: blobURL(for: entry.id)),
              let box = try? AES.GCM.SealedBox(combined: sealedData),
              let data = try? AES.GCM.open(box, using: key) else { return nil }
        return data
    }

    /// Удаляет blob-ы без записей. Вызывается ТОЛЬКО после успешной
    /// расшифровки хранилища: при сбое загрузки или недоступном ключе
    /// blob-ы не трогаем — их записи могут вернуться.
    private func sweepOrphanBlobs() {
        guard keyIsPersistent,
              Self.fileState(at: Self.unreadableBackupURL(for: storageURL)) == .absent else { return }
        // Пока сохранена копия истории, её изображения тоже сохраняются.
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
        // maintenanceSuspended: PrivacyCleanup начал удаление данных —
        // ЛЮБАЯ запись воскресила бы историю ключом, которого больше нет.
        guard keyIsPersistent, !screenLocked, !isUnreadable,
              !Self.maintenanceSuspended else { return false }
        do {
            let payload = try JSONEncoder().encode(Payload(entries: entries))
            let sealed = try AES.GCM.seal(payload, using: key).combined!
            try sealed.write(to: storageURL, options: .atomic)
            if lastSaveFailed { lastSaveFailed = false }
            return true
        } catch {
            lastSaveFailed = true
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

    // MARK: Локальный ключ

    nonisolated static let localKeyFileName = "clipboard-history.key"

    /// Один файловый ключ для всех сборок, без обращений к связке ключей.
    /// При ошибке старые файлы остаются нетронутыми, запись отключается.
    /// Явный storageURL позволяет проверять миграцию на временных данных.
    nonisolated static func obtainKey(storageURL: URL? = nil) -> (SymmetricKey, Bool) {
        let history = storageURL ?? defaultStorageURL()
        let directory = history.deletingLastPathComponent()
        let url = directory.appendingPathComponent(localKeyFileName)
        do {
            try FileManager.default.createDirectory(at: directory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Не меняем права через ссылку и не принимаем чужой каталог.
            let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_uid == geteuid(), fchmod(fd, 0o700) == 0 else {
                throw CocoaError(.fileReadNoPermission)
            }

            if let data = try localKeyData(at: url) {
                guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
                return (SymmetricKey(data: data), true)
            }

            // Старый файл сохраняем: он может открывать резервную копию.
            // Проверяем ключ по существующей истории до переноса.
            let legacy = directory.appendingPathComponent("debug-history.key")
            var inherited: SymmetricKey?
            if let data = try localKeyData(at: legacy) {
                if data.count == 32 {
                    inherited = SymmetricKey(data: data)
                } else {
                    switch salvagedKey(from: data, historyAt: history) {
                    case let .recovered(key): inherited = key
                    case .hopeless: break
                    case .unverifiable: throw CocoaError(.fileReadCorruptFile)
                    }
                }
            }
            let key = inherited ?? SymmetricKey(size: .bits256)
            switch historyState(for: key, at: history) {
            case .opens: break
            case .absent:
                if inherited == nil {
                    // Остатки истории без ключа нельзя обрекать на удаление
                    // последующей уборкой blob-ов с новым случайным ключом.
                    let blobs = history.deletingPathExtension().appendingPathExtension("blobs")
                    guard fileState(at: unreadableBackupURL(for: history)) == .absent,
                          fileState(at: blobs) == .absent ||
                            (try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) == [] else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
            case .doesNotOpen, .unreadable: throw CocoaError(.fileReadCorruptFile)
            }

            // O_EXCL не позволяет затереть ключ параллельного запуска;
            // права 0600 действуют с первого байта, до записи материала.
            let output = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: key.withUnsafeBytes { Data($0) })
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                discardKeyFile(at: url)
                throw error
            }
            return (key, true)
        } catch {
            NSLog("Aza: local history key unavailable (%@) — history is read-only this session",
                  error.localizedDescription)
            return (SymmetricKey(size: .bits256), false)
        }
    }

    /// Отсутствие отличается от ошибки. Не читаем ссылки, устройства,
    /// чужие файлы или произвольные объёмы вместо короткого ключа.
    private nonisolated static func localKeyData(at url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), info.st_size <= 4096,
              fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileReadNoPermission) }
        return try handle.read(upToCount: 4097) ?? Data()
    }

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

        // Ограничение по объёму — до любых преобразований: файл ключа
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

    /// Имя копии выводится ОДНИМ способом на весь файл: разъехавшиеся
    /// формулы дали бы защиту, которая защищает не тот файл.
    nonisolated static func unreadableBackupURL(for history: URL) -> URL {
        history.deletingPathExtension().appendingPathExtension("unreadable.bin")
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

}
