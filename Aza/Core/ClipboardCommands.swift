import AppKit
import Combine

/// Единый владелец операций над историей буфера: копирование, вставка,
/// удаление с окном «Отменить», массовое удаление.
///
/// Зачем отдельный тип: панель меню и остров — два интерфейса над одной
/// историей. Если каждый держит своё `lastDeleted` и свой таймер, они
/// перетирают друг другу окно отмены и могут финализировать чужой пакет.
/// Здесь окно одно на приложение.
@MainActor
final class ClipboardCommands: ObservableObject {

    /// Последняя операция — для строки статуса в любом интерфейсе.
    @Published private(set) var status = ""
    /// Удалённое, что ещё можно вернуть (пусто — кнопки «Отменить» нет).
    @Published private(set) var pendingUndo: [ClipboardStore.Deleted] = []

    /// Хранилище появляется асинхронно (ключ Keychain добывается в фоне).
    private let storeProvider: () -> ClipboardStore?
    private var undoToken = UUID()

    /// Сколько живёт окно «Отменить» (спецификация §8.7).
    static let undoWindow: TimeInterval = 5

    init(storeProvider: @escaping () -> ClipboardStore?) {
        self.storeProvider = storeProvider
    }

    var store: ClipboardStore? { storeProvider() }

    // MARK: Копирование и вставка

    /// Кладёт запись в системный буфер сообразно её виду.
    @discardableResult
    func copyToPasteboard(_ entry: ClipEntry) -> Bool {
        guard let store else { return false }
        let pasteboard = NSPasteboard.general
        // clearContents — только после того, как данные добыты: неудача
        // (нечитаемый blob) не должна стирать прежнее содержимое буфера.
        switch entry.resolvedKind {
        case .files:
            let urls = (entry.filePaths ?? []).map { URL(fileURLWithPath: $0) as NSURL }
            guard !urls.isEmpty else {
                status = "Файлы недоступны"
                return false
            }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls)
        case .image:
            guard let data = store.imageData(for: entry) else {
                status = "Изображение недоступно"
                return false
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: .png)
        case .rtf:
            pasteboard.clearContents()
            if let rtf = entry.rtfData { pasteboard.setData(rtf, forType: .rtf) }
            pasteboard.setString(entry.text, forType: .string)
        case .text, .link:
            pasteboard.clearContents()
            pasteboard.setString(entry.text, forType: .string)
        }
        status = "Скопировано — вставьте ⌘V"
        store.touch(id: entry.id)
        return true
    }

    /// Копирует и пытается вставить в поле приложения, которое было
    /// активным до открытия нашего интерфейса. Не-текстовые виды
    /// остаются в буфере: AX-вставка умеет только текст.
    func insertIntoActiveApp(_ entry: ClipEntry) {
        guard copyToPasteboard(entry) else { return }
        guard entry.resolvedKind != .image, entry.resolvedKind != .files else {
            status = "В буфере — вставьте ⌘V в нужном месте"
            return
        }
        status = "Вставляю в активное приложение…"
        NSApp.hide(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
            guard let self else { return }
            guard let element = TextInsertion.focusedElement(),
                  TextInsertion.isTextLike(element) else {
                // AX не видит поле (Electron, webview) — запись уже в
                // буфере, добиваем синтетическим ⌘V, как вставка фраз.
                self.status = TextInsertion.postPasteCommand()
                    ? "Вставлено в активное приложение"
                    : "Поле не найдено — текст в буфере (⌘V)"
                return
            }
            guard !SecureFieldDetector.isSecure(element) else {
                self.status = "Защищённое поле — вставьте ⌘V"
                return
            }
            let caretBefore = TextInsertion.caretPosition(of: element)
            guard TextInsertion.insert(entry.text, into: element) == .success else {
                self.status = TextInsertion.postPasteCommand()
                    ? "Вставлено в активное приложение"
                    : "Прямая вставка не поддержана — ⌘V"
                return
            }
            self.status = "Вставлено в активное приложение"
            // Electron может ответить success, ничего не вставив: каретка
            // обязана сдвинуться. Добиваем ⌘V только при точно неподвижной
            // каретке — двойная вставка хуже пропущенной.
            guard let caretBefore else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
                if TextInsertion.caretPosition(of: element) == caretBefore {
                    _ = TextInsertion.postPasteCommand()
                }
            }
        }
    }

    // MARK: Удаление и отмена

    func delete(_ entry: ClipEntry) {
        guard let store, let deleted = store.delete(id: entry.id) else { return }
        beginUndoWindow([deleted])
    }

    /// Массовое удаление (§8.7): избранное пропускает само хранилище.
    func deleteAll(_ entries: [ClipEntry]) {
        guard let store else { return }
        beginUndoWindow(store.deleteBatch(ids: entries.map(\.id)))
    }

    func undo() {
        guard let store else { return }
        pendingUndo.forEach { store.restore($0) }
        pendingUndo = []
        status = "Удаление отменено"
    }

    func clearAll() {
        store?.clearAll()
        status = "История очищена (избранное сохранено)"
    }

    /// Блокировка экрана (§8.9): расшифрованные записи не должны пережить
    /// её даже в окне «Отменить». Токен сбрасывается, чтобы просроченный
    /// таймер ничего не финализировал после разблокировки.
    func wipeOnLock() {
        pendingUndo = []
        undoToken = UUID()
        status = ""
    }

    /// Прошлый пакет финализируется, новый живёт `undoWindow` секунд.
    /// Токен защищает от того, что просроченный таймер финализирует уже
    /// заменённый или возвращённый пакет.
    private func beginUndoWindow(_ batch: [ClipboardStore.Deleted]) {
        guard let store, !batch.isEmpty else { return }
        pendingUndo.forEach { store.finalizeDelete($0) }
        pendingUndo = batch
        status = batch.count == 1 ? "Удалено" : "Удалено записей: \(batch.count)"
        let token = UUID()
        undoToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoWindow) { [weak self] in
            guard let self, self.undoToken == token, !self.pendingUndo.isEmpty else { return }
            let expired = self.pendingUndo
            self.pendingUndo = []
            expired.forEach { store.finalizeDelete($0) }
        }
    }

    // MARK: Поиск

    /// Фильтр + сортировка: избранное сверху, затем по свежести.
    static func filtered(entries: [ClipEntry], query: String) -> [ClipEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matched = query.isEmpty
            ? entries
            : entries.filter { $0.text.lowercased().contains(query) }
        return matched.sorted {
            if ($0.isFavorite == true) != ($1.isFavorite == true) {
                return $0.isFavorite == true
            }
            return $0.createdAt > $1.createdAt
        }
    }
}
