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
                self?.resize(for: mode, animated: true)
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
        resize(for: store.mode, animated: false)
        setVisible(store.isIslandVisible, animated: false)
    }

    private func setVisible(_ visible: Bool, animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if visible {
            guard !panel.isVisible else {
                panel.alphaValue = 1
                return
            }
            panel.alphaValue = animated ? 0 : 1
            panel.orderFrontRegardless()
            guard animated else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduceMotion ? AzaMotion.micro : AzaMotion.compact
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        } else {
            let duration = animated ? (reduceMotion ? AzaMotion.micro : AzaMotion.compact) : 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.04))
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

    private func resize(for mode: IslandMode, animated: Bool) {
        guard let screen = activeScreen else { return }
        let hasNotch = screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
        store.hasNotch = hasNotch
        let size = mode.size(hasNotch: hasNotch)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = AzaMotion.expand
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            panel.animator().setFrame(frame, display: true)
        }
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
        let isInActivationArea = IslandHitTesting.hoverRect(
            in: screen.frame,
            hasNotch: hasNotch(on: screen)
        ).contains(mouse)
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
    static func hoverRect(in screen: NSRect, hasNotch: Bool) -> NSRect {
        let width: CGFloat = hasNotch ? 240 : 180
        return NSRect(x: screen.midX - width / 2, y: screen.maxY - 42, width: width, height: 42)
    }
}

