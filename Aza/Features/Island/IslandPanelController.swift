import AppKit
import ApplicationServices
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
    /// Контекстное меню карточек (.contextMenu): hosting-вью отдаёт NSMenu
    /// через menu(for:), но по цепочке ответчиков от вложенного
    /// HostingScrollView правый клик до показа меню не доходит (проверено
    /// 04.09: menu(for:) у hit-вью nil, tracking NSMenu не начинается).
    /// Показываем сами штатным popUpContextMenu.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let host = contentView,
           let menu = host.menu(for: event) {
            azaDebugLog("Aza: panel context menu \(menu.items.map(\.title))")
            NSMenu.popUpContextMenu(menu, with: event, for: host)
            return
        }
        super.sendEvent(event)
    }
}

/// Панель неактивирующая, поэтому приложение при клике не активируется и
/// КАЖДЫЙ клик для macOS — «первый по неактивному приложению»: без этого
/// override система не доносит mouseDown до вью, и тапы по острову
/// (открыть большой режим, кнопки внутри) не срабатывают вовсе.
/// Не дженерик намеренно: generic-наследник NSHostingView роняет
/// swift-frontend 6.3.3 (SIGSEGV в SILPerformanceInliner на deinit)
/// при сборке Release. Единственный Content всё равно IslandRootView.
private final class FirstMouseHostingView: NSHostingView<IslandRootView> {
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
    /// Сквозной номер синтезированных событий: у реальной мыши он растёт,
    /// и SwiftUI по нему различает жесты.
    private var syntheticEventNumber = 1
    private func nextEventNumber() -> Int { syntheticEventNumber += 1; return syntheticEventNumber }
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
        panel.becomesKeyOnlyIfNeeded = true
        // Вставка текста вызывает NSApp.hide(). Островом управляет своя
        // видимость: системное скрытие оставляло его невидимым при
        // isIslandVisible == true, и следующий режим не показывал окно.
        panel.canHide = false
        // Иначе sendEvent(mouseMoved) — пересланный из монитора для
        // hover карточек — окно роняет, не доходя до tracking-областей.
        panel.acceptsMouseMovedEvents = true
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
                    // Без first responder фокус SwiftUI (.focused в
                    // onAppear) не берётся, и до первого клика по карточке
                    // стрелки/Enter/Esc молчали — Enter «вставить
                    // последнее» сразу после хоткея не работал.
                    self.panel.makeFirstResponder(self.panel.contentView)
                    // Из окна значка меню-бара панель key не получает: то
                    // окно ещё key и закрывается позже. Повтор после его
                    // ухода — иначе Esc/стрелки/Enter в буфере мертвы.
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
                        guard let self, self.store.mode == .clipboard,
                              !SystemScreenCapture.isSelecting,
                              !self.panel.isKeyWindow else { return }
                        azaDebugLog("Aza: clipboard panel re-key (delayed)")
                        self.panel.makeKeyAndOrderFront(nil)
                        self.panel.makeFirstResponder(self.panel.contentView)
                    }
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
                // На первом запуске Accessibility ещё нет. После выдачи
                // права пробуем снова; уже установленный tap не дублируем.
                if self.clickTap == nil, AXIsProcessTrusted() { self.installClickTap() }
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
        if old.isKeyWindow { old.resignKey() }
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
        var size = mode.size(hasNotch: hasNotch, notchWidth: store.notchWidth)
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
        installDebugHooks()
    }

    /// Живые тесты (память aza-island-clicks): настройки открываются без
    /// клика по острову — `notify aza.debug.openSetup` из scratchpad, —
    /// чтобы стенд не останавливал диктовку владельца. Только DEBUG.
    private func installDebugHooks() {
        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("aza.debug.openSetup"), object: nil, queue: .main
        ) { [weak self] _ in
            azaDebugLog("Aza: debug openSetup")
            self?.store.openSetup()
        }
        // Диагностика меню (память aza-island-clicks): открылось ли,
        // дошёл ли клик до петли, выбран ли пункт.
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                     NSMenu.didSendActionNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { n in
                azaDebugLog("Aza: NSMenu \(n.name.rawValue) \((n.object as? NSMenu)?.items.map(\.title) ?? [])")
            }
        }
        #endif
    }

    /// Открытие/закрытие острова кликом ловит CGEventTap, а не
    /// NSEvent-мониторы или SwiftUI-жесты: tap видит каждый клик в HID-
    /// потоке независимо от того, кому WindowServer доставил событие, —
    /// глобальный монитор не видит кликов по собственным окнам, а жест в
    /// неключевой неактивирующей панели хрупок (first mouse).
    private func installClickTap() {
        guard clickTap == nil, AXIsProcessTrusted() else { return }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.rightMouseUp.rawValue)
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
                // Снимок области — системный модальный жест. Пропускаем
                // down/drag/up, Space, Esc и модификаторы ДО всех наших
                // меню, хоткеев и попыток вернуть панели key-статус.
                if azaAssumeMainUnchecked({ SystemScreenCapture.isSelecting }) {
                    azaAssumeMainUnchecked {
                        controller.forwardingDrag = false
                        controller.forwardTarget = nil
                    }
                    return Unmanaged.passUnretained(event)
                }
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
                    // Своя вставка должна дойти до поля, минуя хоткеи и UI Aza.
                    guard event.getIntegerValueField(.eventSourceUserData) != TextInsertion.syntheticEventMarker
                    else { return Unmanaged.passUnretained(event) }
                    let handled = azaAssumeMainUnchecked { () -> Bool in
                        if type == .keyDown || type == .keyUp {
                            let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
                            let mods = HotKeyBinding.carbonModifiers(fromCG: event.flags)
                            if HotKeyController.handleTapKey(
                                keyCode: keyCode, carbonModifiers: mods,
                                isDown: type == .keyDown,
                                sourceUserData: event.getIntegerValueField(.eventSourceUserData)
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
        guard !SystemScreenCapture.isSelecting else { return }
        let mouse = NSEvent.mouseLocation
        handleMouseMoved(at: mouse)
        // Hover карточек/фраз (onHover → NSTrackingArea): AppKit панели
        // движения не доставляет, как и клики, — шлём mouseMoved сами.
        // Только буфер/фразы: home подсвечивает зоны опросом.
        if store.isIslandVisible, store.mode == .clipboard || store.mode == .phrases,
           isInsideIsland(mouse),
           let moved = NSEvent.mouseEvent(
               with: .mouseMoved, location: panel.convertPoint(fromScreen: mouse),
               modifierFlags: [], timestamp: event.timestamp,
               windowNumber: panel.windowNumber, context: nil,
               eventNumber: nextEventNumber(), clickCount: 0, pressure: 0
           ) {
            panel.sendEvent(moved)
        }
    }

    /// Возвращает true, если событие нужно ПРОГЛОТИТЬ (не пускать в
    /// приложение): клики по острову обрабатываются здесь целиком —
    /// на этой macOS AppKit молча роняет клики по расширенной панели
    /// (доходит только полоса меню-бара), поэтому SwiftUI-кнопкам
    /// события не достаются в принципе.
    private func handleClick(at mouse: NSPoint, type: CGEventType,
                             flags: CGEventFlags = []) -> Bool {
        // Открытое меню (Picker звука, контекстные): нативно приложению
        // не приходит НИЧЕГО (как и всем окнам — см. память
        // aza-island-clicks), поэтому клик по пункту постим в очередь
        // событий приложения: tracking-петля NSMenu читает именно её
        // (тот же механизм, что чинил NSSegmentedControl ниже). Окно
        // меню NSApp не резолвит — событие идёт с windowNumber 0 и
        // экранными координатами, tracking-петля хит-тестит их сама.
        // Пересылать в окно ПОД меню нельзя (настройки перекрыты меню),
        // висящий пересланный жест сбрасываем. Drag не проверяем:
        // CGWindowList на каждом drag-событии системного потока дорог.
        if type != .leftMouseDragged, let menu = ownMenuOnScreen() {
            forwardingDrag = false
            forwardTarget = nil
            // rightMouseUp — завершение правого клика, открывшего
            // контекстное меню: петля ждёт его из очереди.
            guard type == .leftMouseDown || type == .leftMouseUp
                || type == .rightMouseUp else { return false }
            // Окно MenuBarExtra — тот же уровень popUpMenu, но NSApp его
            // резолвит. Штатно оно закрывается при потере key-статуса,
            // которого у вечно неактивного приложения нет: клик мимо
            // закрываем сами повторным action значка (toggle).
            if let extra = NSApp.window(withWindowNumber: menu.number),
               !extra.frame.contains(mouse) {
                if type == .leftMouseDown, let button = statusBarButton() {
                    azaDebugLog("Aza: menubar extra dismiss")
                    Task { @MainActor in button.performClick(nil) }
                }
                return true
            }
            // Событие «без окна» (windowNumber 0, экранные координаты)
            // петля поглощает, но считает промахом и закрывает меню без
            // выбора. Нужны номер окна меню и координаты в нём; mouseMoved
            // перед down ставит подсветку на пункт (нативные движения
            // курсора до петли не доходят, выбор идёт по подсветке).
            let local = NSPoint(x: mouse.x - menu.frame.minX, y: mouse.y - menu.frame.minY)
            azaDebugLog("Aza: menu branch type=\(type.rawValue) win=\(menu.number) local=\(local)")
            let types: [NSEvent.EventType] = switch type {
            case .leftMouseDown: [.mouseMoved, .leftMouseDown]
            case .rightMouseUp: [.rightMouseUp]
            default: [.leftMouseUp]
            }
            for evType in types {
                guard let event = NSEvent.mouseEvent(
                    with: evType, location: local, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: menu.number, context: nil,
                    eventNumber: nextEventNumber(), clickCount: 1, pressure: 1
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            return true
        }
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
        // Значок меню-бара (NSStatusBarButton в NSStatusBarWindow): стоит
        // внутри кадра компактного острова и из пересылки исключён —
        // action кнопки жмём напрямую (performClick без tracking-петли),
        // MenuBarExtra открывает своё окно сам. Асинхронно — из tap'а
        // реентерабельный показ окна клинит SwiftUI-мост.
        if type == .leftMouseDown || type == .leftMouseUp,
           !(inside && store.isIslandVisible),
           let button = statusBarButton(at: mouse) {
            if type == .leftMouseDown {
                azaDebugLog("Aza: menubar icon click")
                Task { @MainActor in button.performClick(nil) }
            }
            return true
        }
        // Светофор титулбара: AppKit кликов приложению не доставляет, а
        // кормить нативную tracking-петлю NSButton без очереди событий
        // нельзя (повиснет) — действие окна жмём напрямую по хит-тесту.
        if type == .leftMouseDown, !(inside && store.isIslandVisible),
           let window = forwardableWindow(at: mouse),
           window.parent == nil, window.styleMask.contains(.titled),
           mouse.y >= window.frame.maxY - 30,
           let action = trafficLightAction(in: window, at: mouse) {
            action()
            return true
        }
        // Окно настроек и его шторки/поповеры: AppKit им клики тоже не
        // доставляет — пересылка, как у панели. Титулбар (верхние 30 пт)
        // верхнеуровневого титулованного окна не трогаем: нативные
        // tracking-петли перетаскивания повисли бы без очереди событий.
        if type == .leftMouseDown, !(inside && store.isIslandVisible),
           let window = forwardableWindow(at: mouse),
           !(window.parent == nil && window.styleMask.contains(.titled)
             && mouse.y >= window.frame.maxY - 30) {
            if store.isIslandVisible { store.dismissIsland() }
            azaDebugLog("Aza: forward down -> \(window.className) #\(window.windowNumber) parent=\(window.parent?.windowNumber ?? 0) local=\(window.convertPoint(fromScreen: mouse))")
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
        // Контекстное меню карточки: правый клик — в очередь событий
        // приложения (postEvent), а не sendEvent: contextMenu запускает
        // tracking-петлю NSMenu, которая читает rightMouseUp из очереди;
        // sendEvent из Task в этой петле не выполнился бы. Выбор пункта
        // затем идёт веткой ownMenuOnScreen выше.
        if inside, store.isIslandVisible,
           store.mode == .clipboard || store.mode == .phrases,
           type == .rightMouseDown || type == .rightMouseUp {
            if let event = NSEvent.mouseEvent(
                with: type == .rightMouseDown ? .rightMouseDown : .rightMouseUp,
                location: panel.convertPoint(fromScreen: mouse), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber, context: nil,
                eventNumber: nextEventNumber(), clickCount: 1, pressure: 1
            ) {
                NSApp.postEvent(event, atStart: false)
            }
            return true
        }
        if type == .leftMouseUp {
            guard interactive else { return false }
            switch store.mode {
            case .idle:
                azaDebugLog("Aza: island click -> home")
                store.show(.home)
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
        if HotKeyController.isRecordingShortcut, type != .scrollWheel,
           KeyCatcher.forward(cgEvent, to: keyForwardTarget()) {
            // Отпускания модификаторов нужны и уже запущенной hold-диктовке.
            return type != .flagsChanged
        }
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
            let islandScroll = store.isIslandVisible
                && (store.mode == .clipboard || store.mode == .phrases)
                && isInsideIsland(point)
            if let window = islandScroll ? panel : forwardableWindow(at: point) {
                // Скролл острова/настроек/поповера — вью под курсором
                // напрямую: sendEvent маршрутизирует по locationInWindow, а
                // у события из CGEvent координаты экранные — hitTest уходил
                // мимо (у панели у кромки экрана — всегда: карточки буфера
                // не листались). Скроллу важны только дельты, не позиция.
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
        } else if store.isIslandVisible, store.mode == .clipboard {
            // ⌘-сочетания — хоткеи, не глотаем; исключение — ⌘A
            // (выделить все карточки), она живёт в панели.
            if cgEvent.flags.contains(.maskCommand) {
                let keycode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
                guard keycode == 0 else { return false } // kVK_ANSI_A
            }
            // Открытый буфер — клавиши его, даже если key-статус панели
            // слетел (после контекстного меню клавиши уходили в чужое
            // приложение — Delete в поле владельца). Возвращаем статус.
            if !panel.isKeyWindow {
                azaDebugLog("Aza: clipboard panel lost key — re-key")
                panel.makeKeyAndOrderFront(nil)
            }
            target = panel
        } else if let focus = keyForwardTarget() {
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
        // Панель буфера: клавиши — в очередь приложения, как и клики.
        // Клавиша через sendEvent из Task после кликов через postEvent
        // ломала SwiftUI-мост: следующие клики доходили до hosting-вью,
        // но кнопки молчали (04.09). Один путь для всех событий панели.
        if type != .scrollWheel, target === panel, panel.isKeyWindow,
           !(panel.firstResponder is NSTextView) {
            NSApp.postEvent(event, atStart: false)
            return true
        }
        let windowNumber = target.windowNumber
        Task { @MainActor [weak target] in
            guard let target, target.windowNumber == windowNumber else { return }
            // Клавиши — напрямую firstResponder'у: по-настоящему key окно
            // не бывает (система отклоняет makeKey у неактивного
            // приложения), а не-key окну sendEvent клавиши молча роняет.
            // becomeKey даёт только ВИД. Input context неактивного
            // приложения без activate() глотает вставку (TSM).
            // Панель буфера живёт старым путём sendEvent — он работает.
            if type == .scrollWheel
                || (target === panel && !(target.firstResponder is NSTextView)) {
                // Панель без текстового поля — старый путь sendEvent
                // (onKeyPress буфера работает); поле поиска — как поля
                // настроек ниже: без activate() TSM глотает ввод.
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
        guard let focus = focusWindow, focus.isVisible else {
            focusWindow = nil
            return nil
        }
        // Child всегда важнее базового окна: открытый поповер/шторка
        // модальны по смыслу, ввод — им.
        let target = focus.attachedSheet?.isVisible == true
            ? focus.attachedSheet!
            : focus.childWindows?.last(where: { $0.isVisible }) ?? focus
        // Сначала проверяем, что пользователь всё ещё работает с окном.
        // becomeKey ДО этой проверки перехватывал фокус даже при отказе
        // пересылать клавишу, в том числе на пути flagsChanged.
        guard focusIsTopmost(target) else {
            if target.isKeyWindow { target.resignKey() }
            focusWindow = nil
            return nil
        }
        if !target.isKeyWindow { target.becomeKey() }
        return target
    }

    /// Окно клавиатурного фокуса всё ещё верхнее (по центру своего
    /// кадра)? Частичное перекрытие терпим — важно не красть ввод у
    /// окна, целиком накрывшего наше.
    private func focusIsTopmost(_ window: NSWindow) -> Bool {
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        return window.receivesMouse(at: center)
    }

    /// Назначить окну клавиатурный фокус и key-ВИД. Настоящим key-окном
    /// стать нельзя (система отклоняет makeKey у вечно неактивного
    /// приложения), а без key-вида AppKit рисует контролы блёкло и не
    /// показывает рамку фокуса и каретку полей — «окно как неактивное».
    /// becomeKey() включает key-вид принудительно; доставку клавиш это не
    /// меняет — их всё равно несёт tap напрямую респондеру.
    private func assignFocus(_ window: NSWindow) {
        // Родителя поповера/шторки не «разключаем»: transient-поповер
        // следит за key-статусом родителя и закрывался от resignKey ДО
        // доставки клика — строки списка городов были мертвы (04.09).
        if let old = focusWindow, old !== window, old.isKeyWindow,
           window.parent !== old {
            old.resignKey()
        }
        focusWindow = window
        if !window.isKeyWindow { window.becomeKey() }
    }

    /// Окно меню нашего приложения на экране (уровень popUpMenu): номер и
    /// кадр в Cocoa-координатах. NSApp меню-окна не резолвит, поэтому
    /// спрашиваем WindowServer.
    private func ownMenuOnScreen() -> (number: Int, frame: NSRect)? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let pid = ProcessInfo.processInfo.processIdentifier
        let menuLayer = Int(CGWindowLevelForKey(.popUpMenuWindow))
        // Контекстное меню карточки острова AppKit ставит на уровень
        // панели + 1 (1001), не popUpMenu.
        let islandMenuLayer = Int(panel.level.rawValue) + 1
        let screenMaxY = NSScreen.screens.first?.frame.maxY ?? 0
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? Int32) == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == menuLayer || layer == islandMenuLayer,
                  let number = info[kCGWindowNumber as String] as? Int,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let h = b["Height"] ?? 0
            return (number, NSRect(x: b["X"] ?? 0, y: screenMaxY - (b["Y"] ?? 0) - h,
                                   width: b["Width"] ?? 0, height: h))
        }
        return nil
    }

    /// Кнопка светофора под курсором → её действие. Реакция на down, а
    /// не на up: жеста «нажал и увёл» у нас всё равно нет, tracking-петля
    /// кнопки не запускается.
    /// Кнопка значка меню-бара (под курсором, если точка задана). Окно
    /// статус-бара есть в NSApp.windows (в CGWindowList его нет — значок
    /// рисует система), кадр окна = область значка.
    private func statusBarButton(at point: NSPoint? = nil) -> NSStatusBarButton? {
        func find(_ view: NSView?) -> NSStatusBarButton? {
            guard let view else { return nil }
            if let b = view as? NSStatusBarButton { return b }
            for sub in view.subviews { if let b = find(sub) { return b } }
            return nil
        }
        return NSApp.windows.lazy
            .filter { $0.className == "NSStatusBarWindow" && $0.isVisible
                && (point == nil || $0.frame.contains(point!)) }
            .compactMap { find($0.contentView) }
            .first
    }

    private func trafficLightAction(in window: NSWindow,
                                    at mouse: NSPoint) -> (() -> Void)? {
        let buttons: [(NSWindow.ButtonType, () -> Void)] = [
            (.closeButton, { window.performClose(nil) }),
            (.miniaturizeButton, { window.performMiniaturize(nil) }),
            (.zoomButton, { window.performZoom(nil) }),
        ]
        for (kind, action) in buttons {
            guard let button = window.standardWindowButton(kind),
                  !button.isHidden, button.isEnabled else { continue }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            // +2 пт запаса: кнопки крошечные, промах на пиксель не должен
            // превращаться в мёртвый клик.
            if frame.insetBy(dx: -2, dy: -2).contains(mouse) { return action }
        }
        return nil
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
            guard w.receivesMouse(at: point) else { return nil }
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
        // Любое окно, включая панель: AppKit-контролы (Picker(.segmented) →
        // NSSegmentedControl, поле поиска буфера → NSTextView) на
        // sendEvent(down) уходят в нативную tracking-петлю и ждут mouseUp
        // из очереди событий, а Task на main actor в tracking-mode не
        // выполняется (main queue не дренируется) — главный поток висел
        // навсегда (настройки 31.08, поиск буфера 04.09). postEvent кладёт
        // событие в ту самую очередь, которую читают и главный цикл, и
        // tracking-петля; он не обрабатывает UI реентерабельно, поэтому из
        // tap-колбэка (main thread) его звать можно и НУЖНО синхронно.
        // Устаревшая панель: NSApp сам роняет событие с чужим номером окна.
        guard let event = NSEvent.mouseEvent(
            with: evType, location: local, modifierFlags: mods,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: target.windowNumber, context: nil,
            eventNumber: nextEventNumber(), clickCount: forwardClickCount, pressure: 1
        ) else { return }
        NSApp.postEvent(event, atStart: false)
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
            store.show(.clipboard)
        case .settings:
            azaDebugLog("Aza: home action Настройки")
            store.dismissIsland()
            store.openSetup()
        case .exit:
            azaDebugLog("Aza: home action Выход")
            NSApp.terminate(nil)
        case .city:
            azaDebugLog("Aza: home action город")
            store.openSetup(showing: .azaShowPrayerSettings)
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
