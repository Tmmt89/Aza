import AppKit
import Combine
import SwiftUI

enum IslandMode: String, CaseIterable {
    case idle
    case home
    case dictation
    case clipboard

    var shoulder: CGFloat {
        switch self {
        case .home: 42
        case .clipboard: 30
        case .idle: 22
        case .dictation: 20
        }
    }

    var bottomRadius: CGFloat {
        switch self {
        case .idle, .dictation: 22
        case .home, .clipboard: 34
        }
    }

    var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .idle: (0.18, 11, 10)
        case .dictation: (0.16, 10, 10)
        case .home, .clipboard: (0.18, 14, 14)
        }
    }

    func size(hasNotch: Bool) -> NSSize {
        let base: NSSize = switch (self, hasNotch) {
        case (.idle, _): NSSize(width: 430, height: 59)
        case (.home, true): NSSize(width: 780, height: 230)
        case (.home, false): NSSize(width: 700, height: 230)
        case (.dictation, _): NSSize(width: 484, height: 54)
        case (.clipboard, _): NSSize(width: 928, height: 228)
        }
        return NSSize(width: base.width + shoulder * 2, height: base.height)
    }
}

/// Вид карточки для отображения в острове. Отдельный от ClipEntry.Kind
/// enum: у острова свои названия и символы, и он знает про транскрипты
/// диктовки, которых в хранилище нет как отдельного вида.
enum ClipboardKind: String, CaseIterable {
    case text
    case link
    case image
    case files
    case transcript

    var title: String {
        switch self {
        case .text: "Текст"
        case .link: "Ссылка"
        case .image: "Изображение"
        case .files: "Файлы"
        case .transcript: "Транскрипт"
        }
    }

    var symbol: String {
        switch self {
        case .text: "text.alignleft"
        case .link: "link"
        case .image: "photo"
        case .files: "doc.on.doc"
        case .transcript: "mic.fill"
        }
    }
}

/// Мост между хранилищем и островом: остров рендерит настоящие ClipEntry,
/// а недостающие для отрисовки величины вычисляются здесь.
extension ClipEntry {
    var islandKind: ClipboardKind {
        switch resolvedKind {
        case .text, .rtf: sourceAppName == "Aza (диктовка)" ? .transcript : .text
        case .link: .link
        case .image: .image
        case .files: .files
        }
    }

    var sourceApp: String {
        sourceAppName ?? sourceAppBundleID ?? "неизвестно"
    }

    /// Миниатюра из зашифрованного payload: полноразмерный blob для
    /// карточки не расшифровывается.
    var thumbnailImage: NSImage? {
        thumbnailData.flatMap(NSImage.init(data:))
    }

    var fileURLs: [URL] {
        (filePaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    var favorite: Bool { isFavorite == true }

    /// Иконка приложения-источника: хранилище держит только bundle ID,
    /// иконку спрашиваем у системы (и только для установленных программ).
    var sourceAppIcon: NSImage? {
        guard let bundleID = sourceAppBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum ElapsedTime {
    static func short(since date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)с" }
        if seconds < 3_600 { return "\(seconds / 60)м" }
        if seconds < 86_400 { return "\(seconds / 3_600)ч" }
        return "\(seconds / 86_400)д"
    }
}

enum PrayerCountdownPhase: Equatable {
    case hidden
    case minutes(Int)
    case seconds(Int)

    static func make(secondsRemaining: TimeInterval) -> PrayerCountdownPhase {
        guard secondsRemaining > 0, secondsRemaining <= 300 else { return .hidden }
        if secondsRemaining <= 60 { return .seconds(Int(ceil(secondsRemaining))) }
        return .minutes(Int(ceil(secondsRemaining / 60)))
    }
}

/// Состояние ВИДА острова: режим, выделение, видимость, запрос поиска.
/// Данными владеет ClipboardStore, операциями — ClipboardCommands;
/// синглтона намеренно нет — хранилище приходит асинхронно, поэтому
/// остров получает его через ClipboardStartup.
@MainActor
final class IslandStore: ObservableObject {
    @Published var mode: IslandMode = .idle {
        didSet {
            guard oldValue != mode else { return }
            compactVisibleUntil = mode == .idle ? .now.addingTimeInterval(3) : .distantPast
            updateIslandPresence()
        }
    }
    @Published private(set) var isIslandVisible = true
    @Published private(set) var prayerCountdownPhase: PrayerCountdownPhase = .hidden
    @Published var hasNotch = false
    @Published var selectedID: ClipEntry.ID?
    @Published var showsFavorites = false
    @Published var searchQuery = ""

    let prayerCatalog: PrayerCatalog
    let startup: ClipboardStartup
    let dictation: DictationController
    /// Времена намаза: таблица, если есть, иначе расчёт (§4.3).
    let prayer: PrayerStore

    private var compactVisibleUntil = Date.now.addingTimeInterval(3)
    private var suppressedUntil = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []

    init(startup: ClipboardStartup,
         dictation: DictationController,
         prayer: PrayerStore,
         prayerCatalog: PrayerCatalog = .bundled) {
        self.startup = startup
        self.dictation = dictation
        self.prayer = prayer
        self.prayerCatalog = prayerCatalog

        // Остров живёт поверх чужих ObservableObject — пересобираем вид,
        // когда меняется история, окно отмены или состояние диктовки.
        // Хранилище приходит асинхронно, поэтому подписка на него
        // навешивается в момент появления.
        for publisher in [startup.objectWillChange, dictation.objectWillChange,
                          startup.commands.objectWillChange, prayer.objectWillChange] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        startup.$store
            .compactMap { $0 }
            .sink { [weak self] store in
                guard let self else { return }
                store.objectWillChange
                    .sink { [weak self] _ in self?.objectWillChange.send() }
                    .store(in: &self.cancellables)
            }
            .store(in: &cancellables)

        // Диктовка сама поднимает остров в свой режим и опускает обратно.
        dictation.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .recording, .transcribing:
                    // Из ЛЮБОГО режима: иначе запись из открытого буфера
                    // оставила бы панель ключевой и перехватывающей ввод.
                    self.mode = .dictation
                default:
                    if self.mode == .dictation { self.mode = .idle }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: Намаз для интерфейса

    /// Время в часовом поясе ГОРОДА: расписание Грозного, открытое в
    /// поездке, должно оставаться грозненским.
    private func formatted(_ date: Date) -> String {
        if let city = prayer.selectedCity { return city.formattedTime(date) }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    func nextPrayerOccurrence(after now: Date = .now) -> PrayerOccurrence? {
        guard let next = prayer.nextPrayer(after: now) else { return nil }
        return PrayerOccurrence(kind: next.kind, time: formatted(next.date),
                                date: next.date, source: next.source)
    }

    func todayPrayers() -> [PrayerOccurrence] {
        (prayer.today?.occurrences ?? []).map {
            PrayerOccurrence(kind: $0.kind, time: formatted($0.date),
                             date: $0.date, source: $0.source)
        }
    }

    /// Подпись источника (§4.3) — «ДУМ ЧР», «Расчёт MWL» или просьба
    /// выбрать город.
    var prayerSourceLabel: String {
        guard prayer.selectedCity != nil else { return "Город не выбран" }
        return prayer.source?.label ?? "Нет расписания"
    }

    func prayerSourceLabel(for occurrence: PrayerOccurrence?) -> String {
        occurrence?.source?.label ?? prayerSourceLabel
    }

    var commands: ClipboardCommands { startup.commands }
    var entries: [ClipEntry] { startup.store?.entries ?? [] }
    var isHistoryPaused: Bool { startup.monitor?.isRunning == false }


    func updateIslandPresence(now: Date = .now) {
        guard mode == .idle else {
            prayerCountdownPhase = .hidden
            isIslandVisible = true
            return
        }
        let remaining = prayer.nextPrayer(after: now)
            .map { $0.date.timeIntervalSince(now) } ?? .infinity
        prayerCountdownPhase = PrayerCountdownPhase.make(secondsRemaining: remaining)
        isIslandVisible = now < compactVisibleUntil
            || (now >= suppressedUntil && prayerCountdownPhase != .hidden)
    }

    func revealCompactIsland() {
        suppressedUntil = .distantPast
        compactVisibleUntil = .now.addingTimeInterval(3)
        updateIslandPresence()
    }

    func hideCompactIsland(now: Date = .now) {
        compactVisibleUntil = .distantPast
        suppressedUntil = now.addingTimeInterval(8)
        updateIslandPresence(now: now)
    }

    func dismissIsland() {
        mode = .idle
        hideCompactIsland()
    }

    // MARK: Данные и действия — тонкие обёртки над общим владельцем

    func visibleEntries(matching query: String) -> [ClipEntry] {
        let filtered = ClipboardCommands.filtered(entries: entries, query: query)
        return showsFavorites ? filtered.filter(\.favorite) : filtered
    }

    func moveSelection(by offset: Int, in visible: [ClipEntry]) {
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + offset, 0), visible.count - 1)
        selectedID = visible[next].id
    }

    func toggleFavorite(_ id: ClipEntry.ID) {
        startup.store?.toggleFavorite(id: id)
    }

    func delete(_ id: ClipEntry.ID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        commands.delete(entry)
    }

    func undoDelete() {
        commands.undo()
    }

    /// Клик по карточке: положить в буфер и вставить в поле приложения,
    /// из которого пользователь пришёл.
    func reuse(_ id: ClipEntry.ID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        dismissIsland()
        commands.insertIntoActiveApp(entry)
    }
}
