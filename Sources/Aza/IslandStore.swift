import AppKit
import CryptoKit
import SwiftUI

enum IslandMode: String, CaseIterable {
    case idle
    case home
    case dictation
    case clipboard

    var shoulder: CGFloat {
        switch self {
        case .home, .clipboard: 42
        case .idle: 22
        case .dictation: 0
        }
    }

    func size(hasNotch: Bool) -> NSSize {
        let base: NSSize = switch (self, hasNotch) {
        case (.idle, _): NSSize(width: 430, height: 59)
        case (.home, true): NSSize(width: 780, height: 230)
        case (.home, false): NSSize(width: 700, height: 230)
        case (.dictation, true): NSSize(width: 480, height: 38)
        case (.dictation, false): NSSize(width: 340, height: 38)
        case (.clipboard, _): NSSize(width: 820, height: 214)
        }
        return NSSize(width: base.width + shoulder * 2, height: base.height)
    }
}

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

struct ClipboardEntry: Identifiable {
    var id: UUID
    var kind: ClipboardKind
    var text: String
    var sourceApp: String
    var sourceIcon: NSImage?
    var createdAt: Date
    var image: NSImage?
    var fileURLs: [URL]
    var isFavorite: Bool
    let fingerprint: String

    init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        text: String,
        sourceApp: String,
        sourceIcon: NSImage? = nil,
        createdAt: Date = .now,
        image: NSImage? = nil,
        fileURLs: [URL] = [],
        isFavorite: Bool = false,
        fingerprint: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.sourceApp = sourceApp
        self.sourceIcon = sourceIcon
        self.createdAt = createdAt
        self.image = image
        self.fileURLs = fileURLs
        self.isFavorite = isFavorite
        self.fingerprint = fingerprint ?? Fingerprint.make(kind: kind, text: text)
    }
}

enum Fingerprint {
    static func make(kind: ClipboardKind, text: String) -> String {
        let digest = SHA256.hash(data: Data("\(kind.rawValue):\(text)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

@MainActor
final class IslandStore: ObservableObject {
    static let shared = IslandStore()

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
    @Published var entries: [ClipboardEntry]
    @Published var selectedID: ClipboardEntry.ID?
    @Published var showsFavorites = false
    @Published var isHistoryPaused = false
    @Published var lastDeleted: ClipboardEntry?
    @Published var selectedPrayerCityID: String {
        didSet { UserDefaults.standard.set(selectedPrayerCityID, forKey: "selectedPrayerCityID") }
    }

    let prayerCatalog: PrayerCatalog

    private var deletedIndex: Int?
    private var undoGeneration = UUID()
    private var compactVisibleUntil = Date.now.addingTimeInterval(3)
    private var suppressedUntil = Date.distantPast

    init(entries: [ClipboardEntry] = IslandStore.samples, prayerCatalog: PrayerCatalog = .bundled) {
        self.entries = entries
        self.selectedID = entries.first?.id
        self.prayerCatalog = prayerCatalog
        let saved = UserDefaults.standard.string(forKey: "selectedPrayerCityID")
        self.selectedPrayerCityID = prayerCatalog.city(id: saved ?? "")?.id
            ?? prayerCatalog.cities.first(where: { $0.name == "Казань" })?.id
            ?? prayerCatalog.cities.first?.id
            ?? ""
    }

    var selectedPrayerCity: CityPrayerSchedule? {
        prayerCatalog.city(id: selectedPrayerCityID)
    }

    func updateIslandPresence(now: Date = .now) {
        guard mode == .idle else {
            prayerCountdownPhase = .hidden
            isIslandVisible = true
            return
        }
        let remaining = prayerCatalog.nextPrayer(cityID: selectedPrayerCityID, after: now)
            .map { $0.date.timeIntervalSince(now) } ?? .infinity
        prayerCountdownPhase = PrayerCountdownPhase.make(secondsRemaining: remaining)
        isIslandVisible = now < compactVisibleUntil
            || (now >= suppressedUntil && prayerCountdownPhase != .hidden)
    }

    func revealCompactIsland() {
        suppressedUntil = .distantPast
        compactVisibleUntil = .distantFuture
        mode = .idle
        updateIslandPresence()
    }

    func hideCompactIsland(now: Date = .now) {
        guard mode == .idle else { return }
        compactVisibleUntil = .distantPast
        updateIslandPresence(now: now)
    }

    func dismissIsland() {
        mode = .idle
        compactVisibleUntil = .distantPast
        suppressedUntil = .now.addingTimeInterval(300)
        updateIslandPresence()
    }

    func visibleEntries(matching query: String) -> [ClipboardEntry] {
        entries.filter { entry in
            (!showsFavorites || entry.isFavorite)
                && (query.isEmpty
                    || entry.text.localizedCaseInsensitiveContains(query)
                    || entry.sourceApp.localizedCaseInsensitiveContains(query)
                    || entry.kind.title.localizedCaseInsensitiveContains(query))
        }
    }

    func add(_ entry: ClipboardEntry) {
        guard !isHistoryPaused else { return }

        var newest = entry
        if let index = entries.firstIndex(where: { $0.fingerprint == entry.fingerprint }) {
            let old = entries.remove(at: index)
            newest.id = old.id
            newest.isFavorite = old.isFavorite
        }
        newest.createdAt = .now
        entries.insert(newest, at: 0)
        selectedID = newest.id
    }

    func moveSelection(by offset: Int, in visible: [ClipboardEntry]) {
        guard !visible.isEmpty else { return }
        let current = visible.firstIndex { $0.id == selectedID } ?? 0
        selectedID = visible[min(max(current + offset, 0), visible.count - 1)].id
    }

    func toggleFavorite(_ id: ClipboardEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFavorite.toggle()
    }

    func delete(_ id: ClipboardEntry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        deletedIndex = index
        lastDeleted = entries.remove(at: index)
        selectedID = entries.indices.contains(index) ? entries[index].id : entries.last?.id

        let generation = UUID()
        undoGeneration = generation
        Task {
            try? await Task.sleep(for: .seconds(5))
            if undoGeneration == generation {
                lastDeleted = nil
                deletedIndex = nil
            }
        }
    }

    func undoDelete() {
        guard let entry = lastDeleted else { return }
        entries.insert(entry, at: min(deletedIndex ?? 0, entries.count))
        selectedID = entry.id
        lastDeleted = nil
        deletedIndex = nil
        undoGeneration = UUID()
    }

    func reuse(_ id: ClipboardEntry.ID, plainText: Bool = false) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.createdAt = .now
        entries.insert(entry, at: 0)
        selectedID = entry.id

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !plainText, !entry.fileURLs.isEmpty {
            pasteboard.writeObjects(entry.fileURLs.map { $0 as NSURL })
        } else if !plainText, let image = entry.image {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.setString(entry.text, forType: .string)
        }
        mode = .idle
    }

    private static let samples: [ClipboardEntry] = [
        ClipboardEntry(
            kind: .transcript,
            text: "Подготовь краткий итог встречи и отправь его команде.",
            sourceApp: "Aza",
            isFavorite: true
        ),
        ClipboardEntry(
            kind: .text,
            text: "Универсальный локальный помощник для ежедневной работы.",
            sourceApp: "Notes",
            createdAt: .now.addingTimeInterval(-420)
        ),
        ClipboardEntry(
            kind: .link,
            text: "https://github.com/aza-app/aza",
            sourceApp: "Safari",
            createdAt: .now.addingTimeInterval(-1_800)
        ),
        ClipboardEntry(
            kind: .files,
            text: "2 файла",
            sourceApp: "Finder",
            createdAt: .now.addingTimeInterval(-4_000)
        )
    ]
}

@MainActor
enum StoreChecks {
    static func run() -> Bool {
        let first = ClipboardEntry(kind: .text, text: "одинаковый текст", sourceApp: "Notes")
        let other = ClipboardEntry(kind: .text, text: "другой текст", sourceApp: "Safari")
        let deduplicationStore = IslandStore(entries: [first, other])
        deduplicationStore.add(ClipboardEntry(kind: .text, text: "одинаковый текст", sourceApp: "Mail"))

        let pauseStore = IslandStore(entries: [])
        pauseStore.isHistoryPaused = true
        pauseStore.add(ClipboardEntry(kind: .text, text: "секрет", sourceApp: "Notes"))

        let presenceStore = IslandStore(entries: [])
        presenceStore.dismissIsland()
        let dismissed = !presenceStore.isIslandVisible
        presenceStore.revealCompactIsland()
        presenceStore.hideCompactIsland(now: Date(timeIntervalSince1970: 0))
        let hiddenAfterHover = !presenceStore.isIslandVisible
        presenceStore.revealCompactIsland()
        let silhouette = IslandSilhouette(shoulder: 42)
            .path(in: CGRect(x: 0, y: 0, width: 864, height: 230))

        return PrayerScheduleChecks.run()
            && deduplicationStore.entries.count == 2
            && deduplicationStore.entries.first?.id == first.id
            && deduplicationStore.entries.first?.sourceApp == "Mail"
            && pauseStore.entries.isEmpty
            && dismissed
            && presenceStore.isIslandVisible
            && presenceStore.mode == .idle
            && hiddenAfterHover
            && IslandMode.idle.size(hasNotch: true) == NSSize(width: 474, height: 59)
            && silhouette.contains(CGPoint(x: 432, y: 1))
            && !silhouette.contains(CGPoint(x: 10, y: 10))
            && !silhouette.contains(CGPoint(x: 1, y: 100))
            && silhouette.contains(CGPoint(x: 100, y: 100))
            && ElapsedTime.short(since: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 65)) == "1м"
            && PrayerCountdownPhase.make(secondsRemaining: 300) == .minutes(5)
            && PrayerCountdownPhase.make(secondsRemaining: 60) == .seconds(60)
            && PrayerCountdownPhase.make(secondsRemaining: 301) == .hidden
            && IslandHitTesting.hoverRect(
                in: NSRect(x: 0, y: 0, width: 1_000, height: 800),
                hasNotch: true
            ) == NSRect(x: 380, y: 758, width: 240, height: 42)
    }
}
