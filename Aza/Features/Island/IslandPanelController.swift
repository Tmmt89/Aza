import AppKit
import Combine
import SwiftUI

/// Окно острова: безрамочная панель у выреза поверх всех пространств.
///
/// Отличия от прототипа (по ревью):
/// - экран выбирается по курсору, а не NSScreen.main: иначе на втором
///   дисплее панель уезжала на основной;
/// - панель не становится ключевой сама по себе — фокус забирает только
///   явное взаимодействие с режимом буфера, иначе остров воровал бы
///   ввод у активного приложения;
/// - активационную политику не трогаем: приложение уже LSUIElement.

@MainActor
final class IslandPanel: NSPanel {
    // Ключевой панель становится только по требованию (режим буфера
    // с поиском): пассивные режимы не должны отбирать фокус.
    var wantsKey = false
    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }
}

/// Панель неактивирующая, поэтому приложение при клике не активируется и
/// КАЖДЫЙ клик для macOS — «первый по неактивному приложению»: без этого
/// override система не доносит mouseDown до вью, и тапы по острову
/// (открыть большой режим, кнопки внутри) не срабатывают вовсе.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class IslandPanelController {
    private var panel: IslandPanel
    private let store: IslandStore
    private var modeObservation: AnyCancellable?
    private var visibilityObservation: AnyCancellable?
    private var presenceTimer: Timer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var hoverDismissTask: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?
    private var clickTap: CFMachPort?
    private var homeHoverTimer: Timer?
    /// Идёт пересланный жест: down ушёл в окно, drag/up обязаны дойти
    /// туда же, даже если курсор его покинул. Цель — панель (nil) или
    /// обычное окно (настройки).
    private var forwardingDrag = false
    private weak var forwardTarget: NSWindow?
    /// Счёт кликов для синтезированных событий: без него двойной клик
    /// по карточке буфера (вставка) не распознаётся SwiftUI.
    private var lastForwardDown: (time: TimeInterval, at: NSPoint) = (0, .zero)
    private var forwardClickCount = 1
    /// Логический фокус для клавиатуры: приложение никогда не активируется
    /// (активирующий клик роняет тот же AppKit, что и все события), поэтому
    /// NSApp.isActive/keyWindow — вечно пустые. Фокус ведёт tap: окно
    /// последнего пересланного клика; сбрасывается кликом мимо окон
    /// приложения и сменой фронтмост-приложения (⌘Tab, Spotlight).
    private weak var focusWindow: NSWindow?
    private var appActivationObserver: NSObjectProtocol?

    /// Новая панель для каждого размера: входную форму окна WindowServer
    /// замораживает при ПЕРВОМ показе навсегда — ресайз, orderOut/Front,
    /// invalidateShadow её не обновляют. Панель, показанную 534×32, клики
    /// ниже этой полосы не находят никогда, поэтому расширенные режимы
    /// живут в СВЕЖЕМ окне, созданном сразу финальным кадром.
    private static func makePanel(frame: NSRect, store: IslandStore) -> IslandPanel {
        let panel = IslandPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // .screenSaver: остров обязан быть выше системных оверлеев полосы
        // меню-бара и невидимых окон Electron-приложений (VS Code, ChatGPT
        // держат прозрачное окно 65 пт во всю ширину верха). Так же
        // поступают notch-приложения (boring.notch, NotchNook).
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        let hosting = FirstMouseHostingView(rootView: IslandRootView(store: store))
        // SwiftUI не управляет кадром окна: его подгонка размера дралась
        // с анимацией slideIn и оставляла модельный кадр за кромкой.
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    init(store: IslandStore) {
        self.store = store
        panel = Self.makePanel(
            frame: NSRect(origin: .zero, size: store.mode.size(hasNotch: false)),
            store: store
        )

        modeObservation = store.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                if mode != .idle {
                    self?.hoverDismissTask?.cancel()
                    self?.hoverDismissTask = nil
                }
                guard let self else { return }
                // Сначала transition (может ПЕРЕСОЗДАТЬ панель под новый
                // размер), потом ключевой статус — уже у актуального окна.
                // Ключевой панель становится только в режиме буфера ради
                // поиска: у ключевой неактивирующей панели неактивного
                // приложения клики глохнут.
                self.transition(to: mode)
                if mode == .home {
                    self.startHomeHoverPoll()
                } else {
                    self.stopHomeHoverPoll()
                }
                self.panel.wantsKey = (mode == .clipboard)
                if mode == .clipboard {
                    self.panel.makeKeyAndOrderFront(nil)
                } else if self.panel.isKeyWindow {
                    self.panel.resignKey()
                }
                azaDebugLog("Aza: island mode=\(mode) frame=\(self.panel.frame) key=\(self.panel.isKeyWindow ? 1 : 0)")
            }

        visibilityObservation = store.$isIslandVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setVisible(visible, animated: true)
            }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Курсор покоится на плашке — событий mouseMoved нет, и
                // 3-секундная выдержка прятала остров прямо из-под мыши
                // (пользователь целился кликнуть, а панель исчезала).
                // Тик продлевает видимость, пока курсор внутри силуэта.
                if self.store.mode == .idle, self.store.isIslandVisible,
                   self.panel.isVisible, self.isInsideIsland(NSEvent.mouseLocation) {
                    self.store.revealCompactIsland()
                }
                self.store.updateIslandPresence()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer

        // Панель, показанная на полноэкранном пространстве, «усыновляется»
        // им (баг macOS): .canJoinAllSpaces перестаёт действовать, и остров
        // виден только там. Повторный orderFront на каждой смене Space
        // возвращает панель на текущее пространство.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel.isVisible else { return }
                self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                self.panel.orderFrontRegardless()
            }
        }
        // Смена активного приложения (⌘Tab, Spotlight, клик в другое окно
        // через Dock) — пользователь ушёл: клавиши больше не наши.
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            // Собственная активация (SetupWindow.show зовёт activate) —
            // не уход: фокус не сбрасываем.
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let focus = self.focusWindow, focus.isKeyWindow {
                    focus.resignKey()
                }
                self.focusWindow = nil
            }
        }
        installEventMonitors()
    }

    func show() {
        store.updateIslandPresence()
        resize(for: store.mode)
        setVisible(store.isIslandVisible, animated: false)
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        if visible {
            // Прерванный уход разрешится сам: его completion видит, что
            // остров снова нужен, пропускает orderOut и возвращает кадр.
            guard !panel.isVisible else { return }
            // Финальная геометрия считается ДО анимации: остров выезжает
            // из-за кромки экрана на своё место, а не из старого кадра.
            resize(for: store.mode)
            guard animated else {
                panel.orderFrontRegardless()
                return
            }
            panel.slideIn()
        } else {
            guard panel.isVisible else { return }
            guard animated else {
                panel.orderOut(nil)
                return
            }
            panel.slideOut { [weak self] in
                guard let self, !self.store.isIslandVisible else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    /// Экран под курсором: панель обязана следовать за активным
    /// дисплеем (спецификация §3.1), а NSScreen.main — это экран с
    /// клавиатурным фокусом, что на многомониторной сборке не то же самое.
    private var activeScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Смена режима НЕ анимирует окно (анимация ломала доставку кликов) и
    /// пересоздаёт экранную поверхность: входная область окна у
    /// WindowServer замораживается на кадре первого показа, и без
    /// orderOut/orderFront клики доходили только в полосу бывшей
    /// компактной плашки (32 пт сверху), кнопки ниже были глухи.
    /// Смена размера = НОВОЕ окно (см. makePanel): у прежнего входная
    /// форма для кликов навсегда заморожена по кадру первого показа.
    /// Окно не анимируется — кадр сразу финальный (анимация ломала
    /// доставку кликов), одинаковый размер оставляет старое окно.
    private func transition(to mode: IslandMode) {
        let oldSize = panel.frame.size
        resize(for: mode)
        let target = panel.frame
        guard target.size != oldSize else { return }
        let old = panel
        let fresh = Self.makePanel(frame: target, store: store)
        panel = fresh
        if old.isVisible {
            fresh.orderFrontRegardless()
        }
        old.orderOut(nil)
    }

    /// Кадр всегда ставится мгновенно: единственная анимация панели —
    /// спуск из-за кромки и уход за неё (slideIn/slideOut).
    private func resize(for mode: IslandMode) {
        guard let screen = activeScreen else { return }
        let hasNotch = screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        store.hasNotch = hasNotch
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            store.notchWidth = right.minX - left.maxX
            store.notchHeight = screen.safeAreaInsets.top
        }
        var size = mode.size(hasNotch: hasNotch)
        // Компактная плашка и диктовка — ровно высота выреза, ни пикселем толще.
        if mode == .idle || mode == .dictation, hasNotch {
            size.height = screen.safeAreaInsets.top
        }
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        ), display: true)
    }

    private func installEventMonitors() {
        // Клики обрабатывает CGEventTap (installClickTap) — мониторам
        // остаётся только движение курсора для hover-логики.
        let events: NSEvent.EventTypeMask = [.mouseMoved]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
        installClickTap()
    }

    /// Открытие/закрытие острова кликом ловит CGEventTap, а не
    /// NSEvent-мониторы или SwiftUI-жесты: tap видит каждый клик в HID-
    /// потоке независимо от того, кому WindowServer доставил событие, —
    /// глобальный монитор не видит кликов по собственным окнам, а жест в
    /// неключевой неактивирующей панели хрупок (first mouse).
    private func installClickTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let info {
                        let controller = Unmanaged<IslandPanelController>
                            .fromOpaque(info).takeUnretainedValue()
                        Task { @MainActor in controller.reenableClickTap() }
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard let info else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<IslandPanelController>
                    .fromOpaque(info).takeUnretainedValue()
                // CG-координаты — от верхнего левого угла главного экрана;
                // Cocoa — от нижнего левого. Переворот по главному экрану.
                // Источник tap'a добавлен в main runloop — колбэк на
                // главном потоке, доступ к MainActor-состоянию корректен.
                // Клавиатура и скролл: AppKit приложению не доставляет
                // ВООБЩЕ НИЧЕГО (см. память aza-island-clicks). Сначала
                // хоткеи (Carbon-диспетчер мёртв, матчим здесь), потом
                // пересылка в буфер/фразы/настройки.
                if type == .keyDown || type == .keyUp || type == .scrollWheel
                    || type == .flagsChanged {
                    let handled = azaAssumeMainUnchecked { () -> Bool in
                        if type == .keyDown || type == .keyUp {
                            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                            let mods = HotKeyBinding.carbonModifiers(fromCG: event.flags)
                            if HotKeyController.handleTapKey(
                                keyCode: keyCode, carbonModifiers: mods,
                                isDown: type == .keyDown
                            ) { return true }
                        }
                        return controller.forwardKeyOrScrollIfNeeded(event, type: type)
                    }
                    return handled ? nil : Unmanaged.passUnretained(event)
                }
                let loc = event.location
                let flags = event.flags
                let consumed = azaAssumeMainUnchecked {
                    return controller.handleClick(
                        at: NSPoint(
                            x: loc.x,
                            y: (NSScreen.screens.first?.frame.maxY ?? 0) - loc.y
                        ),
                        type: type,
                        flags: flags
                    )
                }
                // Открывающий клик по плашке глотается целиком: если он
                // дойдёт до окна, перестройка острова (.id(mode)) убьёт
                // вью посреди обработки клика, и SwiftUI-мост событий
                // приложения клинит — глохнут и кнопки, и значок меню.
                return consumed ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            azaDebugLog("Aza: island click tap FAILED (нет Accessibility?)")
            return
        }
        clickTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        azaDebugLog("Aza: island click tap installed")
    }

    private func reenableClickTap() {
        if let clickTap { CGEvent.tapEnable(tap: clickTap, enable: true) }
    }

    private func handle(_ event: NSEvent) {
        guard event.type == .mouseMoved else { return }
        handleMouseMoved(at: NSEvent.mouseLocation)
    }

    /// Возвращает true, если событие нужно ПРОГЛОТИТЬ (не пускать в
    /// приложение): клики по острову обрабатываются здесь целиком —
    /// на этой macOS AppKit молча роняет клики по расширенной панели
    /// (доходит только полоса меню-бара), поэтому SwiftUI-кнопкам
    /// события не достаются в принципе.
    private func handleClick(at mouse: NSPoint, type: CGEventType,
                             flags: CGEventFlags = []) -> Bool {
        let inside = isInsideIsland(mouse)
        // Диагностика жалобы «значок в меню-баре некликабелен»: фиксируем
        // каждый клик по полосе меню-бара и решение tap'а по нему.
        if type == .leftMouseDown,
           mouse.y >= (NSScreen.screens.first?.frame.maxY ?? 0) - 24 {
            azaDebugLog("Aza: menubar strip click x=\(Int(mouse.x)) inside=\(inside ? 1 : 0)")
        }
        // Пара к пересланному down: drag и up уходят в панель, даже если
        // курсор уже вне острова — окно не должно остаться с «висящим»
        // нажатием (жест обязан завершиться там, где начался).
        if forwardingDrag {
            switch type {
            case .leftMouseDragged:
                forwardClick(to: forwardTarget, at: mouse, type: type, flags: flags)
                return true
            case .leftMouseUp:
                forwardingDrag = false
                forwardClick(to: forwardTarget, at: mouse, type: type, flags: flags)
                forwardTarget = nil
                return true
            default:
                break
            }
        }
        if type == .leftMouseDragged { return false }
        // Окно настроек и его шторки/поповеры: AppKit им клики тоже не
        // доставляет — пересылка, как у панели. Титулбар (верхние 30 пт)
        // верхнеуровневого титулованного окна не трогаем: нативные
        // tracking-петли перетаскивания повисли бы без очереди событий.
        if type == .leftMouseDown, !(inside && store.isIslandVisible),
           let window = forwardableWindow(at: mouse),
           !(window.parent == nil && window.styleMask.contains(.titled)
             && mouse.y >= window.frame.maxY - 30) {
            if store.isIslandVisible { store.dismissIsland() }
            // Фокус — ДО пересылки: down диспетчеризуется из очереди
            // позже, к этому моменту key-вид и адрес клавиш уже назначены.
            assignFocus(window)
            forwardingDrag = true
            forwardTarget = window
            forwardClick(to: window, at: mouse, type: type, flags: flags)
            return true
        }
        let interactive = inside && store.isIslandVisible
            && (store.mode == .idle || store.mode == .home || store.mode == .dictation)
        // Карточки буфера/фраз: ручных зон нет — down уходит в окно
        // синтезированным NSEvent (drag и up дошлёт ветка forwardingDrag).
        if inside, store.isIslandVisible,
           store.mode == .clipboard || store.mode == .phrases,
           type == .leftMouseDown {
            forwardingDrag = true
            forwardClick(at: mouse, type: type, flags: flags)
            return true
        }
        if type == .leftMouseUp {
            guard interactive else { return false }
            switch store.mode {
            case .idle:
                azaDebugLog("Aza: island click -> home")
                store.mode = .home
            case .dictation:
                // Вся плашка записи — одна кнопка «стоп»: целиться в
                // квадратик на полоске в 32 пт не нужно.
                azaDebugLog("Aza: island click -> stop dictation")
                store.dictation.stopFromUI()
            default:
                performHomeAction(at: mouse)
            }
            return true
        }
        // mouseDown по кликабельной зоне — глотаем (пара к up); в home
        // мимо зон down уходит в окно (drag/up дошлёт ветка forwardingDrag):
        // прочие кликабельные места home работают через sendEvent.
        if type == .leftMouseDown, interactive {
            if store.mode == .home, homeZone(at: mouse) == nil {
                forwardingDrag = true
                forwardClick(at: mouse, type: type, flags: flags)
            }
            return true
        }
        // mouseDown/rightMouseDown мимо острова и окон приложения:
        // закрыть остров, отдать клавиатурный фокус (и снять key-вид).
        if type == .leftMouseDown || type == .rightMouseDown {
            if let focus = focusWindow, focus.isKeyWindow { focus.resignKey() }
            focusWindow = nil
        }
        if store.isIslandVisible, !inside {
            store.dismissIsland()
        }
        return false
    }

    /// Клавиатура (стрелки, поиск, Esc) и скролл для буфера: AppKit их
    /// панели тоже не доставляет. Клавиши — только в режиме буфера при
    /// ключевой панели и без ⌘ (⌘-сочетания — хоткеи, их глотать нельзя;
    /// в фразах цифры — тоже хоткеи, там не трогаем). Скролл — когда
    /// курсор над островом. Событие глотается, чтобы не утекло в фоновое
    /// приложение.
    private func forwardKeyOrScrollIfNeeded(_ cgEvent: CGEvent, type: CGEventType) -> Bool {
        if type == .flagsChanged {
            // Модификаторы рекордеру хоткея (fn/⌃/⌥ пишутся на
            // отпускании) — и НИКОГДА не глотаем: ⌘ из ⌘Tab и прочие
            // системные жесты должны жить.
            if let focus = keyForwardTarget(),
               let event = NSEvent(cgEvent: cgEvent),
               let responder = focus.firstResponder, responder !== focus {
                Task { @MainActor in responder.flagsChanged(with: event) }
            }
            return false
        }
        let target: NSWindow
        if type == .scrollWheel {
            let loc = cgEvent.location
            let point = NSPoint(x: loc.x,
                                y: (NSScreen.screens.first?.frame.maxY ?? 0) - loc.y)
            if store.isIslandVisible,
               store.mode == .clipboard || store.mode == .phrases,
               isInsideIsland(point) {
                target = panel
            } else if let window = forwardableWindow(at: point) {
                // Скролл настроек/поповера — вью под курсором напрямую:
                // sendEvent маршрутизирует по locationInWindow, а у события
                // из CGEvent координаты экранные — hitTest уходил мимо.
                // Скроллу важны только дельты, не позиция.
                guard let event = NSEvent(cgEvent: cgEvent) else { return false }
                let local = window.convertPoint(fromScreen: point)
                let windowNumber = window.windowNumber
                Task { @MainActor [weak window] in
                    guard let window, window.windowNumber == windowNumber,
                          let view = window.contentView?.hitTest(local) else { return }
                    view.scrollWheel(with: event)
                }
                return true
            } else {
                return false
            }
        } else if store.isIslandVisible, store.mode == .clipboard, panel.isKeyWindow {
            // ⌘-сочетания — хоткеи, не глотаем; исключение — ⌘A
            // (выделить все карточки), она живёт в панели.
            if cgEvent.flags.contains(.maskCommand) {
                let keycode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
                guard keycode == 0 else { return false } // kVK_ANSI_A
            }
            target = panel
        } else if let focus = keyForwardTarget(), focusIsTopmost(focus) {
            // Фокус мог протухнуть: настройки остались открыты, но их
            // накрыло чужое окно — клавиши (и особенно ⌘Q) тогда не
            // наши, пусть идут системе (та же дыра, что у мыши).
            // Печать в настройках/шторках/поповерах: NSApp.isActive здесь
            // не бывает true (AppKit роняет и активирующий клик), фокус
            // ведёт tap — окно последнего пересланного клика или его
            // верхний child (поповер поиска города забирает ввод сразу
            // при открытии, клика внутрь не требуется).
            // ⌘-сочетания системные, не глотаем; исключения: ⌘W —
            // закрыть окно/шторку, ⌘Q — выйти из Aza (фокус наш — quit
            // чужого приложения был бы сюрпризом), ⌘, — настройки уже
            // открыты, правки текста и ⌘./⌘Return/⌘Delete.
            if cgEvent.flags.contains(.maskCommand) {
                let keycode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
                switch keycode {
                case 13: // kVK_ANSI_W
                    if type == .keyDown { focus.performClose(nil) }
                    return true
                case 12: // kVK_ANSI_Q
                    if type == .keyDown { NSApp.terminate(nil) }
                    return true
                case 43: // kVK_ANSI_Comma — настройки уже перед глазами
                    return true
                // 0=A 6=Z 7=X 8=C 9=V 47=«.» 36=Return 51=Delete
                case 0, 6, 7, 8, 9, 47, 36, 51:
                    break
                default:
                    return false
                }
            }
            target = focus
        } else {
            return false
        }
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        let windowNumber = target.windowNumber
        Task { @MainActor [weak target] in
            guard let target, target.windowNumber == windowNumber else { return }
            // Клавиши — напрямую firstResponder'у: по-настоящему key окно
            // не бывает (система отклоняет makeKey у неактивного
            // приложения), а не-key окну sendEvent клавиши молча роняет.
            // becomeKey даёт только ВИД. Input context неактивного
            // приложения без activate() глотает вставку (TSM).
            // Панель буфера живёт старым путём sendEvent — он работает.
            if type == .scrollWheel || target === panel {
                target.sendEvent(event)
            } else if let responder = target.firstResponder, responder !== target {
                (responder as? NSView)?.inputContext?.activate()
                if event.type == .keyUp {
                    responder.keyUp(with: event)
                } else if event.modifierFlags.contains(.command) {
                    // ⌘-команды: сперва эквиваленты окна (кнопки со
                    // .keyboardShortcut), затем текстовые команды поля —
                    // меню-путь NSApp у неактивного приложения мёртв.
                    if target.performKeyEquivalent(with: event) { return }
                    let sel: Selector? = switch event.keyCode {
                    case 0: #selector(NSText.selectAll(_:))
                    case 6: Selector(("undo:"))
                    case 7: #selector(NSText.cut(_:))
                    case 8: #selector(NSText.copy(_:))
                    case 9: #selector(NSText.paste(_:))
                    default: nil
                    }
                    if let sel {
                        responder.tryToPerform(sel, with: nil)
                    } else {
                        responder.keyDown(with: event)
                    }
                } else {
                    // Вне текстового поля Return/Esc — сперва кнопке по
                    // умолчанию (.keyboardShortcut), как сделал бы AppKit.
                    if !(responder is NSTextView),
                       target.performKeyEquivalent(with: event) { return }
                    responder.keyDown(with: event)
                }
            } else if event.type == .keyDown,
                      target.performKeyEquivalent(with: event) {
                // Return/Esc без фокусного поля — кнопке по умолчанию.
            } else {
                target.sendEvent(event)
            }
        }
        return true
    }

    /// Куда слать клавиши: открытая поверх фокусного окна шторка или
    /// поповер забирают ввод сами (автофокус поиска города), клик внутрь
    /// им не нужен. Приоритет: in-process key-окно из связки фокусного →
    /// шторка → верхний child → само фокусное окно.
    private func keyForwardTarget() -> NSWindow? {
        guard let focus = focusWindow, focus.isVisible else { return nil }
        // Child всегда важнее базового окна: открытый поповер/шторка
        // модальны по смыслу, ввод — им.
        let target = focus.attachedSheet?.isVisible == true
            ? focus.attachedSheet!
            : focus.childWindows?.last(where: { $0.isVisible }) ?? focus
        if !target.isKeyWindow { target.becomeKey() }
        return target
    }

    /// Окно клавиатурного фокуса всё ещё верхнее (по центру своего
    /// кадра)? Частичное перекрытие терпим — важно не красть ввод у
    /// окна, целиком накрывшего наше.
    private func focusIsTopmost(_ window: NSWindow) -> Bool {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return isTopmostRegularWindow(window, atCG: CGPoint(
            x: center.x,
            y: (NSScreen.screens.first?.frame.maxY ?? 0) - center.y
        ))
    }

    /// Назначить окну клавиатурный фокус и key-ВИД. Настоящим key-окном
    /// стать нельзя (система отклоняет makeKey у вечно неактивного
    /// приложения), а без key-вида AppKit рисует контролы блёкло и не
    /// показывает рамку фокуса и каретку полей — «окно как неактивное».
    /// becomeKey() включает key-вид принудительно; доставку клавиш это не
    /// меняет — их всё равно несёт tap напрямую респондеру.
    private func assignFocus(_ window: NSWindow) {
        if let old = focusWindow, old !== window, old.isKeyWindow {
            old.resignKey()
        }
        focusWindow = window
        if !window.isKeyWindow { window.becomeKey() }
    }

    /// Наше окно под точкой ЗАКРЫТО чужим? Tap видит только окна Aza, и
    /// без этой проверки клик по браузеру, лежащему ПОВЕРХ забытых
    /// настроек, крался бы невидимой Aza (дыра в чужом окне). Обход
    /// CGWindowList front-to-back по обычному слою: первым содержащее
    /// точку окно должно быть нашим.
    private func isTopmostRegularWindow(_ window: NSWindow, atCG cgPoint: CGPoint) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        let pid = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                         width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                    .contains(cgPoint)
            else { continue }
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32,
                  owner == pid,
                  let number = info[kCGWindowNumber as String] as? Int
            else { return false }
            return number == window.windowNumber
        }
        return true
    }

    /// ВЕРХНЕЕ окно приложения под точкой, которому можно пересылать
    /// события: настройки (титулованное) и их child-окна — шторки .sheet
    /// и поповеры (нетитулованные, у них есть parent). Обход по z-порядку
    /// (windowNumbers — front-to-back), иначе клик по шторке уходил в
    /// затемнённого родителя. Панель острова, окна меню (события получают
    /// нативно, NSApp их не резолвит) и значок меню-бара (нет parent, не
    /// титулован — tracking-петле NSButton форвард доверять нельзя) —
    /// исключены.
    private func forwardableWindow(at point: NSPoint) -> NSWindow? {
        guard let numbers = NSWindow.windowNumbers(options: []) else { return nil }
        for number in numbers {
            guard let w = NSApp.window(withWindowNumber: number.intValue),
                  w !== panel, w.isVisible, w.frame.contains(point),
                  w.parent != nil || w.styleMask.contains(.titled)
            else { continue }
            // Чужое окно поверх нашего — событие не наше.
            let cg = CGPoint(
                x: point.x,
                y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y
            )
            guard isTopmostRegularWindow(w, atCG: cg) else { return nil }
            return w
        }
        return nil
    }

    /// Досылка проглоченного tap'ом клика в панель вручную: AppKit сам
    /// события расширенной панели роняет, но panel.sendEvent честно
    /// прогоняет hitTest и жмёт SwiftUI-кнопки. Асинхронно — из колбэка
    /// CGEventTap звать sendEvent нельзя: реентерабельная обработка UI
    /// клинит SwiftUI-мост событий (вчерашние «глохнут кнопки и значок»).
    private func forwardClick(to explicitTarget: NSWindow? = nil,
                              at mouse: NSPoint, type: CGEventType,
                              flags: CGEventFlags = []) {
        let target = explicitTarget ?? panel
        let evType: NSEvent.EventType
        switch type {
        case .leftMouseDown: evType = .leftMouseDown
        case .leftMouseDragged: evType = .leftMouseDragged
        default: evType = .leftMouseUp
        }
        // Двойной клик по карточке — «вставить»: SwiftUI различает его
        // только по clickCount, таймер и радиус — как системные.
        if type == .leftMouseDown {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastForwardDown.time < NSEvent.doubleClickInterval,
               abs(mouse.x - lastForwardDown.at.x) < 4,
               abs(mouse.y - lastForwardDown.at.y) < 4 {
                forwardClickCount += 1
            } else {
                forwardClickCount = 1
            }
            lastForwardDown = (now, mouse)
        }
        var mods: NSEvent.ModifierFlags = []
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskCommand) { mods.insert(.command) }
        let local = target.convertPoint(fromScreen: mouse)
        let windowNumber = target.windowNumber
        let clickCount = forwardClickCount
        if explicitTarget != nil {
            // Обычное окно (настройки): AppKit-контролы (Picker(.segmented) →
            // NSSegmentedControl) на sendEvent(down) уходят в нативную
            // tracking-петлю и ждут mouseUp из очереди событий, а Task на
            // main actor в tracking-mode не выполняется (main queue не
            // дренируется) — главный поток висел навсегда, всё приложение
            // «тормозило». postEvent кладёт событие в ту самую очередь,
            // которую читают и главный цикл, и tracking-петля; он не
            // обрабатывает UI реентерабельно, поэтому из tap-колбэка
            // (main thread) его звать можно и НУЖНО синхронно.
            guard let event = NSEvent.mouseEvent(
                with: evType, location: local, modifierFlags: mods,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber, context: nil,
                eventNumber: 0, clickCount: clickCount, pressure: 1
            ) else { return }
            NSApp.postEvent(event, atStart: false)
            return
        }
        Task { @MainActor [weak target] in
            // Панель могла пересоздаться между down и up — устаревшее
            // событие в новое окно не шлём.
            guard let target, target.windowNumber == windowNumber,
                  let event = NSEvent.mouseEvent(
                      with: evType, location: local, modifierFlags: mods,
                      timestamp: ProcessInfo.processInfo.systemUptime,
                      windowNumber: windowNumber, context: nil,
                      eventNumber: 0, clickCount: clickCount, pressure: 1
                  ) else { return }
            target.sendEvent(event)
        }
    }

    /// Ручной хит-тест кнопок home-острова по координатам курсора.
    /// ponytail: зоны сняты с макета и привязаны к правому краю панели;
    /// поменяется вёрстка HomeIslandView — сдвинуть зоны. Гео-кнопка
    /// живёт внутри вью (CityLocator) и отсюда недоступна — её клик
    /// открывает настройки намаза, как и город.
    private func homeZone(at mouse: NSPoint) -> HomeZone? {
        let frame = panel.frame
        // Локальные координаты от ВЕРХНЕГО левого угла панели.
        let x = mouse.x - frame.minX
        let y = frame.maxY - mouse.y
        let w = frame.width
        // Нижний ряд кнопок правой карточки: Диктовка · Буфер · Настройки.
        if (140...205).contains(y) {
            switch w - x {
            case 235...320: return .dictation
            case 155..<235: return .clipboard
            case 75..<155: return .settings
            default: break
            }
        }
        // Верхняя строка карточки: «Выход» в правом углу.
        if (52...88).contains(y), (30...110).contains(w - x) { return .exit }
        // Строка местоположения: гео-стрелка слева от имени города.
        if (80...112).contains(y), (292...334).contains(w - x) { return .geo }
        if (80...112).contains(y), (150...290).contains(w - x) { return .city }
        return nil
    }

    private func performHomeAction(at mouse: NSPoint) {
        let frame = panel.frame
        azaDebugLog("Aza: home click local=(\(Int(mouse.x - frame.minX)), \(Int(frame.maxY - mouse.y))) width=\(Int(frame.width))")
        switch homeZone(at: mouse) {
        case .dictation:
            azaDebugLog("Aza: home action Диктовка")
            store.dictation.startLatchedFromUI()
        case .clipboard:
            azaDebugLog("Aza: home action Буфер")
            store.mode = .clipboard
        case .settings:
            azaDebugLog("Aza: home action Настройки")
            store.dismissIsland()
            store.openSetup()
        case .exit:
            azaDebugLog("Aza: home action Выход")
            NSApp.terminate(nil)
        case .city:
            azaDebugLog("Aza: home action город")
            store.dismissIsland()
            store.openSetup()
            NotificationCenter.default.post(name: .azaShowPrayerSettings, object: nil)
        case .geo:
            azaDebugLog("Aza: home action геопозиция")
            // CityLocator живёт внутри HomeIslandView — команда уходит
            // нотификацией, вью запускает locate() сама.
            NotificationCenter.default.post(name: .azaLocateCity, object: nil)
        case nil:
            break
        }
    }

    /// Hover-подсветка кнопок home: mouseMoved до панели не доходит
    /// (AppKit роняет события расширенной панели), поэтому курсор
    /// опрашивается таймером — только пока home открыт.
    /// ponytail: опрос 60 мс вместо событийной модели — событий нет физически.
    private func startHomeHoverPoll() {
        stopHomeHoverPoll()
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.store.mode == .home else { return }
                let mouse = NSEvent.mouseLocation
                let zone = self.isInsideIsland(mouse) ? self.homeZone(at: mouse) : nil
                if self.store.homeHoverZone != zone { self.store.homeHoverZone = zone }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        homeHoverTimer = timer
    }

    private func stopHomeHoverPoll() {
        homeHoverTimer?.invalidate()
        homeHoverTimer = nil
        if store.homeHoverZone != nil { store.homeHoverZone = nil }
    }

    private func handleMouseMoved(at mouse: NSPoint) {
        guard let screen = activeScreen else { return }
        let isInActivationArea = IslandHitTesting.hoverRect(on: screen).contains(mouse)
        let isInCompactIsland = store.mode == .idle
            && store.isIslandVisible
            && isInsideIsland(mouse)

        if isInActivationArea || isInCompactIsland {
            hoverDismissTask?.cancel()
            hoverDismissTask = nil
            if !store.isIslandVisible {
                store.revealCompactIsland()
            }
            return
        }

        guard store.mode == .idle,
              store.isIslandVisible,
              store.prayerCountdownPhase == .hidden
        else { return }

        hoverDismissTask?.cancel()
        hoverDismissTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(160))
            } catch {
                return
            }
            guard let self, self.store.mode == .idle else { return }
            self.store.hideCompactIsland()
        }
    }

    private func isInsideIsland(_ screenPoint: NSPoint) -> Bool {
        // Прямоугольник кадра, а не силуэт: «плечи» выреза — мёртвые зоны
        // в несколько пикселей, промах по которым читался как клик мимо
        // острова и закрывал его. +1 пт сверху — у кромки экрана курсор
        // репортится ровно на границе, а NSRect.contains верхнюю грань
        // исключает (та же поправка, что в hoverRect).
        var rect = panel.frame
        rect.size.height += 1
        return rect.contains(screenPoint)
    }
}

enum IslandHitTesting {
    /// Зона наведения — сам вырез, а не полоса «где-то рядом»: его
    /// границы система отдаёт через «плечевые» области экрана, высота —
    /// safe-area сверху. Чуть левее или правее выреза остров не выпадает.
    /// Лишний 1 пт сверху — курсор у кромки экрана репортится ровно на
    /// границе, а NSRect.contains верхнюю грань исключает.
    static func hoverRect(on screen: NSScreen) -> NSRect {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else {
            // Экран без выреза: физической границы нет, остаётся полоса
            // по центру меню-бара.
            let width: CGFloat = 180
            return NSRect(x: screen.frame.midX - width / 2,
                          y: screen.frame.maxY - 42, width: width, height: 43)
        }
        let height = max(screen.safeAreaInsets.top, 24)
        return NSRect(x: left.maxX, y: screen.frame.maxY - height,
                      width: right.minX - left.maxX, height: height + 1)
    }
}

