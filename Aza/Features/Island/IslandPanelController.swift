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
            | (1 << CGEventType.rightMouseDown.rawValue)
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
                let loc = event.location
                let consumed = MainActor.assumeIsolated {
                    controller.handleClick(
                        at: NSPoint(
                            x: loc.x,
                            y: (NSScreen.screens.first?.frame.maxY ?? 0) - loc.y
                        ),
                        type: type
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
    private func handleClick(at mouse: NSPoint, type: CGEventType) -> Bool {
        let inside = isInsideIsland(mouse)
        let interactive = inside && store.isIslandVisible
            && (store.mode == .idle || store.mode == .home || store.mode == .dictation)
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
        // mouseDown по кликабельной зоне — глотаем (пара к up).
        if type == .leftMouseDown, interactive { return true }
        // mouseDown/rightMouseDown мимо острова — закрыть.
        if store.isIslandVisible, !inside {
            store.dismissIsland()
        }
        return false
    }

    /// Ручной хит-тест кнопок home-острова по координатам клика.
    /// ponytail: зоны сняты с макета и привязаны к правому краю панели;
    /// поменяется вёрстка HomeIslandView — сдвинуть зоны. Гео-кнопка
    /// живёт внутри вью (CityLocator) и отсюда недоступна — её клик
    /// открывает настройки намаза, как и город.
    private func performHomeAction(at mouse: NSPoint) {
        let frame = panel.frame
        // Локальные координаты от ВЕРХНЕГО левого угла панели.
        let x = mouse.x - frame.minX
        let y = frame.maxY - mouse.y
        let w = frame.width
        azaDebugLog("Aza: home click local=(\(Int(x)), \(Int(y))) width=\(Int(w))")
        // Нижний ряд кнопок правой карточки: Диктовка · Буфер · Настройки.
        if (140...205).contains(y) {
            switch w - x {
            case 235...320:
                azaDebugLog("Aza: home action Диктовка")
                store.dictation.startLatchedFromUI()
                return
            case 155..<235:
                azaDebugLog("Aza: home action Буфер")
                store.mode = .clipboard
                return
            case 75..<155:
                azaDebugLog("Aza: home action Настройки")
                store.dismissIsland()
                store.openSetup()
                return
            default: break
            }
        }
        // Верхняя строка карточки: «Выход» в правом углу.
        if (52...88).contains(y), (30...110).contains(w - x) {
            azaDebugLog("Aza: home action Выход")
            NSApp.terminate(nil)
            return
        }
        // Строка местоположения: гео-стрелка и имя города → настройки
        // намаза с выбором города.
        if (80...112).contains(y), (150...290).contains(w - x) {
            azaDebugLog("Aza: home action город")
            store.dismissIsland()
            store.openSetup()
            NotificationCenter.default.post(name: .azaShowPrayerSettings, object: nil)
            return
        }
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

