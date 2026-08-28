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

@MainActor
final class IslandPanelController {
    private let panel: IslandPanel
    private let store: IslandStore
    private var modeObservation: AnyCancellable?
    private var visibilityObservation: AnyCancellable?
    private var presenceTimer: Timer?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var hoverDismissTask: Task<Void, Never>?

    init(store: IslandStore) {
        self.store = store
        panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: store.mode.size(hasNotch: false)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: IslandRootView(store: store))

        modeObservation = store.$mode
            .removeDuplicates()
            .sink { [weak self] mode in
                if mode != .idle {
                    self?.hoverDismissTask?.cancel()
                    self?.hoverDismissTask = nil
                }
                self?.panel.wantsKey = (mode == .clipboard)
                if mode == .clipboard {
                    self?.panel.makeKeyAndOrderFront(nil)
                } else if self?.panel.isKeyWindow == true {
                    self?.panel.resignKey()
                }
                self?.transition(to: mode)
            }

        visibilityObservation = store.$isIslandVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setVisible(visible, animated: true)
            }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak store] _ in
            guard let store else { return }
            Task { @MainActor in store.updateIslandPresence() }
        }
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
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

    /// Смена режима — один жест, без промежуточных фаз: кадр панели
    /// сразу ставится финальным за кромкой (контент к этому моменту уже
    /// в новом облике — морф в IslandRootView отключён), и новая панель
    /// целиком опускается из выреза поверх прежней. Подъём старой и
    /// морф старого кадра давали кашу из трёх дерущихся анимаций.
    private func transition(to mode: IslandMode) {
        resize(for: mode)
        guard panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        panel.slideIn()
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
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown]
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        switch event.type {
        case .mouseMoved:
            handleMouseMoved(at: mouse)
        case .leftMouseDown, .rightMouseDown:
            guard store.isIslandVisible, !isInsideIsland(mouse) else { return }
            store.dismissIsland()
        default:
            break
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

    private func hasNotch(on screen: NSScreen) -> Bool {
        screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
    }

    private func isInsideIsland(_ screenPoint: NSPoint) -> Bool {
        guard panel.frame.contains(screenPoint) else { return false }
        let localPoint = CGPoint(
            x: screenPoint.x - panel.frame.minX,
            y: panel.frame.maxY - screenPoint.y
        )
        return IslandSilhouette(
            shoulder: store.mode.shoulder,
            bottomRadius: store.mode.bottomRadius
        )
            .path(in: CGRect(origin: .zero, size: panel.frame.size))
            .contains(localPoint)
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

