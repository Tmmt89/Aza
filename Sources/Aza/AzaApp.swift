import AppKit
import Combine
import CryptoKit
import Darwin
import SwiftUI

@main
struct AzaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        guard CommandLine.arguments.contains("--self-check") else { return }
        guard StoreChecks.run() else {
            fputs("Aza self-check failed\n", stderr)
            exit(1)
        }
        print("Aza self-check passed")
        exit(0)
    }

    var body: some Scene {
        MenuBarExtra("Aza", systemImage: "waveform") {
            if let next = IslandStore.shared.prayerCatalog.nextPrayer(
                cityID: IslandStore.shared.selectedPrayerCityID,
                after: .now
            ) {
                Text("\(next.kind.title) · \(next.time)")
                Divider()
            }
            Button("Открыть Aza") {
                IslandStore.shared.mode = .home
            }
            Button("Буфер обмена") {
                IslandStore.shared.mode = .clipboard
            }
            Divider()
            Toggle("Приостановить историю", isOn: Binding(
                get: { IslandStore.shared.isHistoryPaused },
                set: { IslandStore.shared.isHistoryPaused = $0 }
            ))
            Divider()
            Button("Завершить Aza") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            SettingsView(store: .shared)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: IslandPanelController?
    private var clipboardMonitor: ClipboardMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        panelController = IslandPanelController(store: .shared)
        panelController?.show()
        clipboardMonitor = ClipboardMonitor(store: .shared)
        clipboardMonitor?.start()
    }
}

@MainActor
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
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
                self?.resize(for: mode, animated: true)
            }

        visibilityObservation = store.$isIslandVisible
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.setVisible(visible, animated: true)
            }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak store] _ in
            Task { @MainActor in store?.updateIslandPresence() }
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

    private func resize(for mode: IslandMode, animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
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
        return IslandSilhouette(shoulder: store.mode.shoulder)
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

@MainActor
final class ClipboardMonitor {
    private let store: IslandStore
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?

    private let sensitiveTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType"
    ]

    private let excludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "com.lastpass.LastPass",
        "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc",
        "ch.protonmail.pass"
    ]

    init(store: IslandStore) {
        self.store = store
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard !store.isHistoryPaused else { return }

        let rawTypes = Set(pasteboard.types?.map(\.rawValue) ?? [])
        guard rawTypes.isDisjoint(with: sensitiveTypes) else { return }

        let app = NSWorkspace.shared.frontmostApplication
        guard !excludedBundleIDs.contains(app?.bundleIdentifier ?? "") else { return }
        let sourceName = app?.localizedName ?? "Неизвестно"
        let sourceIcon = app.flatMap { application in
            application.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            store.add(ClipboardEntry(
                kind: .files,
                text: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) файла",
                sourceApp: sourceName,
                sourceIcon: sourceIcon,
                fileURLs: urls,
                fingerprint: Fingerprint.make(kind: .files, text: urls.map(\.path).joined(separator: "\n"))
            ))
            return
        }

        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) {
            store.add(ClipboardEntry(
                kind: .image,
                text: "Изображение \(Int(image.size.width)) × \(Int(image.size.height))",
                sourceApp: sourceName,
                sourceIcon: sourceIcon,
                image: image,
                fingerprint: Fingerprint.make(kind: .image, text: SHA256.hash(data: data).description)
            ))
            return
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let kind: ClipboardKind = URL(string: text)?.scheme?.hasPrefix("http") == true ? .link : .text
        store.add(ClipboardEntry(
            kind: kind,
            text: text,
            sourceApp: sourceName,
            sourceIcon: sourceIcon
        ))
    }
}

struct SettingsView: View {
    @ObservedObject var store: IslandStore

    var body: some View {
        Form {
            Picker("Город", selection: $store.selectedPrayerCityID) {
                ForEach(store.prayerCatalog.cities) { city in
                    Text(city.name).tag(city.id)
                }
            }
            if let city = store.selectedPrayerCity {
                LabeledContent("Источник", value: city.source.name)
                if !city.isComplete {
                    Text("Опубликовано только с \(city.coverageStart) по \(city.coverageEnd). За пределами диапазона Aza не подставляет другой календарь.")
                        .foregroundStyle(.orange)
                }
            }
            Divider()
            Toggle("Приостановить историю буфера", isOn: $store.isHistoryPaused)
            Text("Aza обрабатывает историю локально. Этот прототип пока хранит записи только в памяти.")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 440)
    }
}
