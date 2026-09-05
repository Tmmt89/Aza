import AppKit
import ApplicationServices
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
        case .idle: 12
        case .dictation: 22
        }
    }

    var bottomRadius: CGFloat {
        switch self {
        case .idle: 14
        case .dictation: 22
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

    func size(hasNotch: Bool, notchWidth: CGFloat = AzaStyle.notchWidth) -> NSSize {
        let base: NSSize = switch (self, hasNotch) {
        // По 104 pt с каждой стороны реального выреза, включая плечи.
        case (.idle, _): NSSize(width: (hasNotch ? notchWidth : 0) + 208 - shoulder * 2,
                               height: 40)
        // Высота с вырезом переопределяется в IslandPanelController на
        // точную высоту выреза этого экрана; 40 — запасной вариант.
        case (.dictation, true): NSSize(width: 490, height: 40)
        case (.dictation, false): NSSize(width: 360, height: 40)
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
        case .text, .rtf: transcript ? .transcript : .text
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

/// Кликабельные зоны home-острова: ручной хит-тест живёт в
/// IslandPanelController (AppKit роняет события расширенной панели).
enum HomeZone {
    case dictation, clipboard, settings, exit, city, geo
}

/// Состояние ВИДА острова: режим, выделение, видимость, запрос поиска.
/// Данными владеет ClipboardStore, операциями — ClipboardCommands;
/// синглтона намеренно нет — хранилище приходит асинхронно, поэтому
/// остров получает его через ClipboardStartup.
@MainActor
final class IslandStore: ObservableObject {
    @Published private(set) var mode: IslandMode = .idle {
        didSet {
            guard oldValue != mode else { return }
            compactVisibleUntil = mode == .idle
                ? ContinuousClock.now.advanced(by: .seconds(3)) : ContinuousClock.now
            updateIslandPresence()
            syncPhraseDigitHotKeys()
        }
    }

    /// Пока диктовка владеет панелью, завершить её режим может только
    /// подписка на dictation.$state. Это относится и к хоткеям, и к кликам.
    func show(_ requested: IslandMode) {
        guard mode != .dictation else { return }
        mode = requested
    }
    @Published private(set) var isIslandVisible = true
    /// Зона home-острова под курсором. Мышиные события до SwiftUI не
    /// доходят (клики глотает CGEventTap, mouseMoved панель не получает),
    /// поэтому hover-подсветку ведёт IslandPanelController опросом курсора.
    @Published var homeHoverZone: HomeZone?
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

    /// Настройки на нужном разделе. Нотификацию — следующим витком: при
    /// первом открытии окно ещё создаётся, и SetupView, посланный
    /// синхронно, её не слышит (04.09: «Изменить» фраз открывал «Намаз»).
    func openSetup(showing section: Notification.Name) {
        dismissIsland()
        openSetup()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: section, object: nil)
        }
    }

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
    private var hasObservedHistory = false
    /// Последнее залогированное состояние видимости — чтобы лог не
    /// строчил каждую секунду.
    private var lastLoggedPresence: Bool?
    /// Глобальное сочетание «открыть/закрыть буфер» (§8): остров — его
    /// единственный интерфейс, поэтому хоткей живёт здесь.
    private var clipboardHotKey: HotKeyController?
    @Published private(set) var clipboardHotKeyError: String?
    /// Сочетание фраз (hold-режим: держишь — панель видна, отпустил — ушла).
    private var phrasesHotKey: HotKeyController?
    @Published private(set) var phrasesHotKeyError: String?
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
         prayer: PrayerStore,
         registerShortcuts: Bool = true) {
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
                case .preparingRecording, .recording, .transcribing:
                    // Из ЛЮБОГО режима: иначе запись из открытого буфера
                    // оставила бы панель ключевой и перехватывающей ввод.
                    self.mode = .dictation
                default:
                    if self.mode == .dictation { self.mode = .idle }
                }
            }
            .store(in: &cancellables)

        if registerShortcuts {
            rebindClipboardHotKey()
            rebindPhrasesHotKey()
            installPhraseOptionMonitor()
        }
    }

    /// (Пере)регистрация сочетания буфера — при старте и после смены в
    /// настройках. Нажатие переключает остров в режим буфера и обратно.
    @discardableResult
    func rebindClipboardHotKey() -> OSStatus? {
        clipboardHotKeyError = nil
        clipboardHotKey?.stop()
        clipboardHotKey = nil
        let binding = HotKeyBinding.load(HotKeyBinding.clipboardKey,
                                         fallback: .clipboardDefault)
        if let problem = binding.phraseSelectionConflict(for: HotKeyBinding.clipboardKey) {
            clipboardHotKeyError = problem
            return OSStatus(eventHotKeyExistsErr)
        }
        let controller = HotKeyController(
            keyCode: binding.keyCode, modifiers: binding.modifiers, id: 3,
            onPress: { [weak self] in
                guard let self else { return }
                if self.mode == .clipboard {
                    self.dismissIsland()
                } else {
                    self.show(.clipboard)
                }
            }
        )
        clipboardHotKey = controller
        if let status = controller.register() {
            azaDebugLog("Aza: clipboard hotkey registration FAILED status=\(status)")
            clipboardHotKeyError = binding.registrationError(status)
            clipboardHotKey = nil
            return status
        } else {
            azaDebugLog("Aza: clipboard hotkey registered \(binding.display)")
        }
        return nil
    }

    /// (Пере)регистрация сочетания фраз. Hold-режим, как у диктовки:
    /// нажатие показывает панель, отпускание прячет.
    @discardableResult
    func rebindPhrasesHotKey() -> OSStatus? {
        phrasesHotKeyError = nil
        phrasesHotKey?.stop()
        phrasesHotKey = nil
        let binding = HotKeyBinding.load(HotKeyBinding.phrasesKey,
                                         fallback: .phrasesDefault)
        if let problem = binding.phraseSelectionConflict(for: HotKeyBinding.phrasesKey) {
            phrasesHotKeyError = problem
            return OSStatus(eventHotKeyExistsErr)
        }
        let controller = HotKeyController(
            keyCode: binding.keyCode, modifiers: binding.modifiers, id: 4,
            onPress: { [weak self] in
                guard let self, self.mode != .phrases else { return }
                self.phrasesHeldByOption = false
                self.show(.phrases)
            },
            onRelease: { [weak self] in
                guard let self, self.mode == .phrases else { return }
                self.dismissIsland()
            }
        )
        phrasesHotKey = controller
        if let status = controller.register() {
            azaDebugLog("Aza: phrases hotkey registration FAILED status=\(status)")
            phrasesHotKeyError = binding.registrationError(status)
            phrasesHotKey = nil
            return status
        } else {
            azaDebugLog("Aza: phrases hotkey registered \(binding.display)")
        }
        return nil
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
        phrasesHotKeyError = nil
        phraseShiftHeld = NSEvent.modifierFlags.contains(.shift)
        for (comboIndex, modifiers) in binding.phraseDigitModifiers.enumerated() {
            for (index, key) in HotKeyBinding.phraseDigitKeys.enumerated() {
                let controller = HotKeyController(
                    keyCode: key, modifiers: modifiers,
                    id: UInt32(40 + comboIndex * 10 + index),
                    onPress: { [weak self] in
                        self?.insertPhrase(at: index, alternate: modifiers & UInt32(shiftKey) != 0)
                    }
                )
                if let status = controller.register() {
                    phrasesHotKeyError = HotKeyBinding(keyCode: key, modifiers: modifiers)
                        .registrationError(status)
                    azaDebugLog("Aza: phrase digit \(index) mods=\(modifiers) FAILED status=\(status)")
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
            azaAssumeMainUnchecked { self?.handlePhraseFlagsChanged(event) }
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
            guard !SystemScreenCapture.isSelecting else { return }
            // Нажата правая ⌥ без других модификаторов. Из активных
            // режимов (диктовка, буфер) панель не выдёргивается.
            guard mode == .idle || mode == .home else { return }
            phraseHoldTask?.cancel()
            phraseHoldTask = Task { [weak self] in
                try? await Task.sleep(for: Self.phraseHoldDelay)
                guard !Task.isCancelled, let self,
                      !SystemScreenCapture.isSelecting,
                      self.mode == .idle || self.mode == .home else { return }
                // ponytail: ⌥-комбинация, начатая ПОСЛЕ выдержки, всё же
                // покажет панель; отсекать её мониторингом keyDown — если
                // будет раздражать.
                self.phrasesHeldByOption = true
                self.show(.phrases)
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
        // Цель — приложение, активное до скрытия наших окон (как в буфере):
        // отложенный ⌘V-фолбэк не должен улететь туда, куда пользователь
        // успел переключиться. Фронтмост — сама Aza: цель неизвестна, nil.
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let targetPid = frontPid == ProcessInfo.processInfo.processIdentifier
            ? nil : frontPid
        let targetElement = TextInsertion.focusedElement().flatMap {
            TextInsertion.processID(of: $0) == targetPid ? $0 : nil
        }
        if appWasActive { NSApp.hide(nil) }
        azaDebugLog("Aza: insertPhrase index=\(index) appWasActive=\(appWasActive ? 1 : 0)")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(140)) {
            Self.attemptPhraseInsertion(text, retriesLeft: 2, targetPid: targetPid,
                                        targetElement: targetElement)
        }
    }

    /// AX-вставка с повторами: Electron (VS Code, Slack…) строит дерево
    /// доступности асинхронно после пробуждения, и первая попытка часто
    /// не находит поле. Не вышло — фраза кладётся в буфер и вставляется
    /// синтетическим ⌘V: это работает там, где AX бессилен.
    private static func attemptPhraseInsertion(_ text: String, retriesLeft: Int,
                                                targetPid: pid_t?, targetElement: AXUIElement?) {
        let focused = TextInsertion.focusedElement()
        let targetElement = targetElement ?? focused
        let targetPid = targetPid ?? focused.flatMap(TextInsertion.processID(of:))
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard targetPid != ProcessInfo.processInfo.processIdentifier else { return }
        guard TextInsertion.focusSafeForPaste(targetPid: targetPid,
                                              verifying: targetElement) else { return }
        if let element = focused {
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
                        guard caretAfter == caretBefore,
                              TextInsertion.focusSafeForPaste(targetPid: targetPid,
                                                              verifying: element) else { return }
                        azaDebugLog("Aza: insertPhrase caret unmoved, paste fallback")
                        pastePhrase(text, targetPid: targetPid, targetElement: element)
                    }
                    return
                }
            }
        }
        guard retriesLeft == 0 else {
            azaDebugLog("Aza: insertPhrase field not ready, retries left \(retriesLeft)")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220)) {
                attemptPhraseInsertion(text, retriesLeft: retriesLeft - 1,
                                       targetPid: targetPid, targetElement: targetElement)
            }
            return
        }
        pastePhrase(text, targetPid: targetPid, targetElement: targetElement)
    }

    /// Последний рубеж: фраза в системный буфер + синтетический ⌘V.
    /// Единая точка всех ⌘V острова: сюда стекаются и ретраи, и фолбэк
    /// неподвижной каретки, поэтому сверка фокуса живёт именно здесь —
    /// к моменту вызова прошло от 140 мс до ~1 с после хоткея.
    private static func pastePhrase(_ text: String, targetPid: pid_t?, targetElement: AXUIElement?) {
        guard TextInsertion.focusSafeForPaste(targetPid: targetPid, verifying: targetElement) else {
            azaDebugLog("Aza: insertPhrase paste fallback blocked — focus moved or secure")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pasted = TextInsertion.postPasteCommand(targetPid: targetPid, verifying: targetElement)
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
            // Отсчёт и первые две минуты намаза ЗАКРЕПЛЯЮТ остров: ни
            // клик мимо, ни уход курсора его не прячут — раньше любой
            // клик по другому приложению убирал плашку на 8 секунд, и
            // она мигала «исчез—появился» все пять минут.
            isIslandVisible = prayerCountdownPhase != .hidden
                || PrayerOccurrence.current(in: todayPrayers(), at: now) != nil
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
        let seenBefore = hasObservedHistory
        hasObservedHistory = true
        guard let top, startup.store?.screenLocked != true else {
            recentCopyTask?.cancel()
            recentCopyTask = nil
            recentCopy = nil
            lastTopID = nil
            lastTopStamp = nil
            return
        }
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
        // Диктовку кликом мимо острова не сворачиваем: панель живёт,
        // пока запись не завершится сама (dictation.$state → .idle).
        guard mode != .dictation else { return }
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
