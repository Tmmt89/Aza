import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum IslandMode: String, CaseIterable {
    case idle
    case home
    case dictation
    case clipboard
    case phrases

    var shoulder: CGFloat {
        switch self {
        case .home: 42
        case .clipboard, .phrases: 30
        case .idle, .dictation: 22
        }
    }

    var bottomRadius: CGFloat {
        switch self {
        case .idle, .dictation: 22
        case .home, .clipboard, .phrases: 34
        }
    }

    var shadow: (opacity: Double, radius: CGFloat, y: CGFloat) {
        switch self {
        case .idle: (0.18, 11, 10)
        case .dictation: (0.16, 10, 10)
        case .home, .clipboard, .phrases: (0.18, 14, 14)
        }
    }

    func size(hasNotch: Bool) -> NSSize {
        let base: NSSize = switch (self, hasNotch) {
        // Компактный режим оставляет вырез свободным, но не растягивает
        // боковые «крылья» дальше ширины их содержимого.
        // Высота с вырезом переопределяется в IslandPanelController на
        // точную высоту выреза этого экрана; 40 — запасной вариант.
        case (.idle, true), (.dictation, true): NSSize(width: 490, height: 40)
        case (.idle, false), (.dictation, false): NSSize(width: 360, height: 40)
        case (.home, true): NSSize(width: 780, height: 230)
        case (.home, false): NSSize(width: 700, height: 230)
        case (.clipboard, _): NSSize(width: 928, height: 228)
        case (.phrases, _): NSSize(width: 820, height: 286)
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

    var favorite: Bool { isFavorite == true }

    var transcript: Bool { isTranscript == true }

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
        if seconds < 10 { return "сейчас" }
        if seconds < 60 { return "меньше минуты" }
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
            compactVisibleUntil = mode == .idle
                ? ContinuousClock.now.advanced(by: .seconds(3)) : ContinuousClock.now
            updateIslandPresence()
            syncPhraseDigitHotKeys()
        }
    }
    @Published private(set) var isIslandVisible = true
    @Published private(set) var prayerCountdownPhase: PrayerCountdownPhase = .hidden
    @Published var hasNotch = false
    /// Реальные размеры выреза этого экрана: у моделей они разные, а
    /// зашитые константы оставляли текст вплотную к вырезу и делали
    /// плашку толще самого выреза.
    @Published var notchWidth: CGFloat = AzaStyle.notchWidth
    @Published var notchHeight: CGFloat = 32
    @Published var selectedID: ClipEntry.ID?
    /// Разделы буфера: транскрипты диктовок живут отдельно и не забивают
    /// историю; избранное — сквозное (и обычные записи, и транскрипты).
    enum ClipSection { case history, favorites, transcripts }
    @Published var section: ClipSection = .history
    /// Свежескопированная запись: компактный остров пару секунд
    /// показывает «Скопировано · тип», затем возвращается к намазу.
    @Published private(set) var recentCopy: ClipEntry?

    /// Настройки реакции на копирование (SetupView, карточка «Общее»).
    static let copyFlashKey = "Island.CopyFlash"
    /// Имя своего звука (Resources/copy-*.caf) или пустая строка — без
    /// звука. Раньше здесь лежали имена системных NSSound — они резкие,
    /// поэтому заменены на синтезированные (Tools/make-copy-sounds.py).
    static let copySoundKey = "Island.CopySound"

    /// Старые сохранённые значения: имена системных звуков и первая
    /// версия своих (drop/chime заменены на pop/ding).
    private static let legacyCopySounds = [
        "Tink": "tick", "Pop": "pop", "Purr": "ding", "Bottle": "marimba",
        "drop": "pop", "chime": "ding",
    ]

    static func playCopySound(_ name: String) {
        guard !name.isEmpty,
              let url = Bundle.main.url(forResource: "copy-\(name)",
                                        withExtension: "caf") else { return }
        NSSound(contentsOf: url, byReference: true)?.play()
    }
    /// Поведение компактного острова: "auto" — показывается на несколько
    /// секунд по событиям, "pinned" — виден всегда, "hidden" — не
    /// появляется вовсе.
    static let compactModeKey = "Island.CompactMode"

    let startup: ClipboardStartup
    let dictation: DictationController
    /// Времена намаза: таблица, если есть, иначе расчёт (§4.3).
    let prayer: PrayerStore
    /// Открыть окно настройки (§3.2: кнопка «Настройки» в главной панели).
    /// Замыкание, а не прямая ссылка: окно создаётся в AzaApp.
    var openSetup: () -> Void = {}

    /// Монотонные дедлайны: wall-clock (Date) прыгает при переводе часов и
    /// NTP-коррекции — остров оставался видимым на величину скачка.
    private var compactVisibleUntil = ContinuousClock.now.advanced(by: .seconds(3))
    private var cancellables: Set<AnyCancellable> = []
    private var recentCopyTask: Task<Void, Never>?
    /// Верхняя запись истории на прошлом снимке: id и createdAt порознь,
    /// потому что дедуп-повтор меняет только время, а вспышки заслуживают
    /// оба случая.
    private var lastTopID: ClipEntry.ID?
    private var lastTopStamp: Date?
    /// Последнее залогированное состояние видимости — чтобы лог не
    /// строчил каждую секунду.
    private var lastLoggedPresence: Bool?
    /// Глобальное сочетание «открыть/закрыть буфер» (§8): остров — его
    /// единственный интерфейс, поэтому хоткей живёт здесь.
    private var clipboardHotKey: HotKeyController?
    /// Сочетание фраз (hold-режим: держишь — панель видна, отпустил — ушла).
    private var phrasesHotKey: HotKeyController?
    /// Цифры 1…0 регистрируются Carbon-хоткеями ТОЛЬКО пока открыта панель
    /// фраз: панель не забирает фокус, и обычный монитор событий не смог бы
    /// проглотить цифру — она допечаталась бы в поле пользователя.
    private var phraseDigitHotKeys: [HotKeyController] = []
    /// Упрощённый вызов фраз: удержание ПРАВОЙ ⌥ без сочетания.
    /// Мониторы flagsChanged — тот же механизм, что у двойного правого
    /// Shift в GlobalHotKey.
    private var phraseOptionMonitors: [Any] = []
    private var phraseHoldTask: Task<Void, Never>?
    /// Панель открыта удержанием ⌥, а не сочетанием: отпускание правой ⌥
    /// закрывает только «свою» панель.
    private var phrasesHeldByOption = false
    /// ⇧ удерживается при открытой панели фраз: цифры вставят вторые
    /// варианты, и панель подсвечивает их таблетки.
    @Published private(set) var phraseShiftHeld = false
    /// Выдержка перед показом: быстрые ⌥-комбинации (спецсимволы,
    /// ⌥-стрелки) не должны дёргать остров.
    private static let phraseHoldDelay: Duration = .milliseconds(300)

    init(startup: ClipboardStartup,
         dictation: DictationController,
         prayer: PrayerStore) {
        self.startup = startup
        self.dictation = dictation
        self.prayer = prayer

        // Разовая миграция: системный звук → свой аналог.
        if let old = UserDefaults.standard.string(forKey: Self.copySoundKey),
           let new = Self.legacyCopySounds[old] {
            UserDefaults.standard.set(new, forKey: Self.copySoundKey)
        }

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
                store.$entries
                    .receive(on: DispatchQueue.main)
                    .sink { [weak self] entries in self?.noteHistoryChange(top: entries.first) }
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

        rebindClipboardHotKey()
        rebindPhrasesHotKey()
        installPhraseOptionMonitor()
    }

    /// (Пере)регистрация сочетания буфера — при старте и после смены в
    /// настройках. Нажатие переключает остров в режим буфера и обратно.
    func rebindClipboardHotKey() {
        clipboardHotKey?.stop()
        clipboardHotKey = nil
        let binding = HotKeyBinding.load(HotKeyBinding.clipboardKey,
                                         fallback: .clipboardDefault)
        let controller = HotKeyController(
            keyCode: binding.keyCode, modifiers: binding.modifiers, id: 3,
            onPress: { [weak self] in
                guard let self else { return }
                if self.mode == .clipboard {
                    self.dismissIsland()
                } else {
                    self.mode = .clipboard
                }
            }
        )
        clipboardHotKey = controller
        if let status = controller.register() {
            azaDebugLog("Aza: clipboard hotkey registration FAILED status=\(status)")
            clipboardHotKey = nil
        } else {
            azaDebugLog("Aza: clipboard hotkey registered \(binding.display)")
        }
    }

    /// (Пере)регистрация сочетания фраз. Hold-режим, как у диктовки:
    /// нажатие показывает панель, отпускание прячет.
    func rebindPhrasesHotKey() {
        phrasesHotKey?.stop()
        phrasesHotKey = nil
        let binding = HotKeyBinding.load(HotKeyBinding.phrasesKey,
                                         fallback: .phrasesDefault)
        let controller = HotKeyController(
            keyCode: binding.keyCode, modifiers: binding.modifiers, id: 4,
            onPress: { [weak self] in
                guard let self, self.mode != .phrases else { return }
                self.phrasesHeldByOption = false
                self.mode = .phrases
            },
            onRelease: { [weak self] in
                guard let self, self.mode == .phrases else { return }
                self.dismissIsland()
            }
        )
        phrasesHotKey = controller
        if let status = controller.register() {
            azaDebugLog("Aza: phrases hotkey registration FAILED status=\(status)")
            phrasesHotKey = nil
        } else {
            azaDebugLog("Aza: phrases hotkey registered \(binding.display)")
        }
    }

    /// Цифры ловятся с ТЕМИ ЖЕ модификаторами, что удерживает пользователь:
    /// при вызове правой ⌥ жмётся ⌥1, при сочетании ⌃⇧F — ⌃⇧1.
    private func syncPhraseDigitHotKeys() {
        guard mode == .phrases else {
            phraseDigitHotKeys.forEach { $0.stop() }
            phraseDigitHotKeys = []
            return
        }
        guard phraseDigitHotKeys.isEmpty else { return }
        let binding = HotKeyBinding.load(HotKeyBinding.phrasesKey,
                                         fallback: .phrasesDefault)
        var modifierSets: [UInt32] = [UInt32(optionKey)]
        if binding.modifiers != UInt32(optionKey) {
            modifierSets.append(binding.modifiers)
        }
        // Каждый набор дублируется с ⇧: вторая форма слота (женский род,
        // полное приветствие) — той же цифрой, без отдельного слота.
        var combos: [(modifiers: UInt32, alternate: Bool)] = []
        for modifiers in modifierSets {
            combos.append((modifiers, false))
            let shifted = modifiers | UInt32(shiftKey)
            if shifted != modifiers { combos.append((shifted, true)) }
        }
        let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                         kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
                         kVK_ANSI_9, kVK_ANSI_0]
        for (comboIndex, combo) in combos.enumerated() {
            for (index, key) in digitKeys.enumerated() {
                let controller = HotKeyController(
                    keyCode: UInt32(key), modifiers: combo.modifiers,
                    id: UInt32(40 + comboIndex * 10 + index),
                    onPress: { [weak self] in
                        self?.insertPhrase(at: index, alternate: combo.alternate)
                    }
                )
                if let status = controller.register() {
                    azaDebugLog("Aza: phrase digit \(index) mods=\(combo.modifiers) FAILED status=\(status)")
                    continue
                }
                phraseDigitHotKeys.append(controller)
            }
        }
    }

    /// Удержание правой ⌥ (kVK_RightOption) показывает панель фраз,
    /// отпускание прячет. Глобальный монитор молчит без Accessibility —
    /// тогда остаётся сочетание.
    private func installPhraseOptionMonitor() {
        let handle: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handlePhraseFlagsChanged(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged, handler: handle) {
            phraseOptionMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged, handler: { handle($0); return $0 }) {
            phraseOptionMonitors.append(local)
        }
        azaDebugLog("Aza: phrase option monitors installed count=\(phraseOptionMonitors.count)")
    }

    private func handlePhraseFlagsChanged(_ event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)
        if phraseShiftHeld != shift { phraseShiftHeld = shift }
        guard event.keyCode == UInt16(kVK_RightOption) else { return }
        // Caps Lock — состояние, а не удерживаемый модификатор: без вычета
        // строгое равенство .option никогда не срабатывало при включённом
        // Caps Lock, и панель фраз не открывалась.
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        azaDebugLog("Aza: right-option flagsChanged option=\(flags == .option ? 1 : 0) mode=\(mode.rawValue)")
        if flags == .option {
            // Нажата правая ⌥ без других модификаторов. Из активных
            // режимов (диктовка, буфер) панель не выдёргивается.
            guard mode == .idle || mode == .home else { return }
            phraseHoldTask?.cancel()
            phraseHoldTask = Task { [weak self] in
                try? await Task.sleep(for: Self.phraseHoldDelay)
                guard !Task.isCancelled, let self,
                      self.mode == .idle || self.mode == .home else { return }
                // ponytail: ⌥-комбинация, начатая ПОСЛЕ выдержки, всё же
                // покажет панель; отсекать её мониторингом keyDown — если
                // будет раздражать.
                self.phrasesHeldByOption = true
                self.mode = .phrases
            }
        } else if !flags.contains(.option) {
            phraseHoldTask?.cancel()
            phraseHoldTask = nil
            guard phrasesHeldByOption else { return }
            phrasesHeldByOption = false
            if mode == .phrases { dismissIsland() }
        }
    }

    /// Вставка фразы в поле, где осталась каретка: панель фраз никогда не
    /// забирает фокус, поэтому вставляем напрямую, без системного буфера.
    /// Поля нет — фраза остаётся в буфере обмена, как в режиме буфера.
    func insertPhrase(at index: Int, alternate: Bool = false) {
        let phrases = PhraseStore.shared.phrases
        guard phrases.indices.contains(index) else { return }
        let text = PhraseStore.variant(phrases[index], alternate: alternate)
        guard !text.isEmpty else { return }
        dismissIsland()
        // Наше окно могло быть активным (например, открыты настройки):
        // прячем приложение, чтобы фокус вернулся в поле пользователя, —
        // и даём системе время на переключение, как делает буфер.
        let appWasActive = NSApp.isActive
        if appWasActive { NSApp.hide(nil) }
        azaDebugLog("Aza: insertPhrase index=\(index) appWasActive=\(appWasActive ? 1 : 0)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) {
            Self.attemptPhraseInsertion(text, retriesLeft: 2)
        }
    }

    /// AX-вставка с повторами: Electron (VS Code, Slack…) строит дерево
    /// доступности асинхронно после пробуждения, и первая попытка часто
    /// не находит поле. Не вышло — фраза кладётся в буфер и вставляется
    /// синтетическим ⌘V: это работает там, где AX бессилен.
    private static func attemptPhraseInsertion(_ text: String, retriesLeft: Int) {
        if let element = TextInsertion.focusedElement() {
            guard !SecureFieldDetector.isSecure(element) else {
                azaDebugLog("Aza: insertPhrase secure field, aborting")
                return
            }
            if TextInsertion.isTextLike(element) {
                let caretBefore = TextInsertion.caretPosition(of: element)
                let result = TextInsertion.insert(text, into: element)
                azaDebugLog("Aza: insertPhrase result=\(result.rawValue)")
                if result == .success {
                    // Electron может ответить success, ничего не вставив.
                    // Каретка обязана сдвинуться; проверяем с задержкой,
                    // чтобы успел и синтетический юникод-путь insert().
                    guard let caretBefore else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
                        let caretAfter = TextInsertion.caretPosition(of: element)
                        // nil или сдвиг — считаем вставленным: двойная
                        // вставка хуже пропущенной.
                        guard caretAfter == caretBefore else { return }
                        azaDebugLog("Aza: insertPhrase caret unmoved, paste fallback")
                        pastePhrase(text)
                    }
                    return
                }
            }
        }
        guard retriesLeft == 0 else {
            azaDebugLog("Aza: insertPhrase field not ready, retries left \(retriesLeft)")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
                attemptPhraseInsertion(text, retriesLeft: retriesLeft - 1)
            }
            return
        }
        pastePhrase(text)
    }

    /// Последний рубеж: фраза в системный буфер + синтетический ⌘V.
    private static func pastePhrase(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pasted = TextInsertion.postPasteCommand()
        azaDebugLog("Aza: insertPhrase paste fallback posted=\(pasted ? 1 : 0)")
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

    /// Подпись ближайшего намаза, ЕСЛИ она отличается от подписи
    /// сегодняшней сетки. После иши ближайший намаз уже завтрашний, а на
    /// границе покрытия расписания завтра может считаться расчётом —
    /// одна общая подпись на два разных источника и есть то самое молчащее
    /// смешивание.
    func differingSourceLabel(for occurrence: PrayerOccurrence?) -> String? {
        guard let label = occurrence?.source?.label,
              label != prayer.source?.label else { return nil }
        return label
    }

    /// Почему времён нет. Пустой экран без объяснения — тоже обман.
    var prayerUnavailableReason: String? { prayer.unavailableReason }

    var commands: ClipboardCommands { startup.commands }
    var entries: [ClipEntry] { startup.store?.entries ?? [] }


    func updateIslandPresence(now: Date = .now) {
        guard mode == .idle else {
            prayerCountdownPhase = .hidden
            isIslandVisible = true
            return
        }
        let remaining = prayer.nextPrayer(after: now)
            .map { $0.date.timeIntervalSince(now) } ?? .infinity
        prayerCountdownPhase = PrayerCountdownPhase.make(secondsRemaining: remaining)
        let compactMode = UserDefaults.standard.string(forKey: Self.compactModeKey)
        switch compactMode {
        case "pinned": isIslandVisible = true
        case "hidden": isIslandVisible = false
        default:
            // Отсчёт до намаза ЗАКРЕПЛЯЕТ остров: пока фаза видима, ни
            // клик мимо, ни уход курсора его не прячут — раньше любой
            // клик по другому приложению убирал плашку на 8 секунд, и
            // она мигала «исчез—появился» все пять минут.
            isIslandVisible = prayerCountdownPhase != .hidden
                || ContinuousClock.now < compactVisibleUntil
        }
        if lastLoggedPresence != isIslandVisible {
            lastLoggedPresence = isIslandVisible
            azaDebugLog("Aza: island presence mode=\(compactMode ?? "nil") visible=\(isIslandVisible)")
        }
    }

    /// Вспышка «Скопировано» в компактном острове. Первый снимок после
    /// запуска — загрузка истории, не копирование; удаление верхней записи
    /// поднимает СТАРУЮ — отсекается проверкой свежести createdAt.
    private func noteHistoryChange(top: ClipEntry?) {
        guard let top else { return }
        let seenBefore = lastTopID != nil
        let changed = top.id != lastTopID || top.createdAt != lastTopStamp
        lastTopID = top.id
        lastTopStamp = top.createdAt
        guard seenBefore, changed,
              Date.now.timeIntervalSince(top.createdAt) < 5 else { return }
        let defaults = UserDefaults.standard
        if let sound = defaults.string(forKey: Self.copySoundKey), !sound.isEmpty {
            Self.playCopySound(sound)
        }
        guard mode == .idle,
              defaults.object(forKey: Self.copyFlashKey) as? Bool ?? true else { return }
        recentCopy = top
        revealCompactIsland()
        recentCopyTask?.cancel()
        recentCopyTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.recentCopy = nil
        }
    }

    func revealCompactIsland() {
        compactVisibleUntil = ContinuousClock.now.advanced(by: .seconds(3))
        updateIslandPresence()
    }

    func hideCompactIsland(now: Date = .now) {
        compactVisibleUntil = ContinuousClock.now
        updateIslandPresence(now: now)
    }

    func dismissIsland() {
        mode = .idle
        hideCompactIsland()
    }

    // MARK: Данные и действия — тонкие обёртки над общим владельцем

    func visibleEntries(matching query: String) -> [ClipEntry] {
        let filtered = ClipboardCommands.filtered(entries: entries, query: query)
        switch section {
        case .history: return filtered.filter { !$0.transcript }
        case .favorites: return filtered.filter(\.favorite)
        case .transcripts: return filtered.filter(\.transcript)
        }
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
