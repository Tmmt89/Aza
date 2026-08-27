import AppKit
import AVFoundation
import ApplicationServices
import Combine
import CoreLocation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Окно первичной настройки (§9) и постоянная страница состояния прав.
///
/// Одна прокручиваемая страница, а не мастер из семи шагов: половина
/// разрешений уводит в системные настройки, и возвращаться в пошаговый
/// мастер неудобно; открытая заново, эта же страница честно показывает,
/// что уже выдано.
@MainActor
final class SetupWindowController {

    static let completedKey = "OnboardingCompleted"

    private var window: NSWindow?
    private let model: SetupModel

    init(model: SetupModel) {
        self.model = model
    }

    /// Показывается сама только при первом запуске; дальше — по команде
    /// из меню.
    func showIfFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.completedKey) else { return }
        show()
    }

    func show() {
        model.refresh()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Размер окна подгоняется под содержимое: настройки должны
        // помещаться целиком, без прокрутки.
        let content = NSHostingView(rootView: SetupView(model: model))
        // Содержимое подгоняем под экран: на маленьком дисплее окно
        // иначе вылезло бы за границы, а скролла в нём нет.
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? CGSize(width: 1280, height: 800)
        let fitting = content.fittingSize
        let size = CGSize(width: min(fitting.width, visible.width - 40),
                          height: min(fitting.height, visible.height - 40))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройка Aza"
        window.isReleasedWhenClosed = false
        // Тёмная сцена без системной полосы: окно — часть продукта,
        // а не стандартный диалог настроек.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 14 / 255, green: 14 / 255,
                                         blue: 16 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.center()
        window.contentView = content
        window.setContentSize(size)
        self.window = window
        // Приложение живёт в меню-баре: без явной активации окно
        // откроется без фокуса, и кнопки будут «не нажиматься».
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Состояние разрешений. Обновляется при каждой активации приложения:
/// Accessibility и Input Monitoring выдаются ВНЕ процесса, и узнать об
/// этом можно только переспросив систему.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoring = CGPreflightListenEventAccess()
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    @Published private(set) var loginItem: SMAppService.Status = .notRegistered
    @Published private(set) var loginItemError: String?

    let prayer: PrayerStore
    let dictation: DictationController
    private var cancellables: Set<AnyCancellable> = []

    init(prayer: PrayerStore, dictation: DictationController) {
        self.prayer = prayer
        self.dictation = dictation
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        axTrusted = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        loginItem = SMAppService.mainApp.status
        Task { [weak self] in
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            self?.notifications = status
        }
    }

    // MARK: Действия

    /// Accessibility выдаётся во внешнем окне и асинхронно: запрос лишь
    /// открывает системные настройки, состояние подхватится при
    /// возвращении в Aza.
    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Input Monitoring вступает в силу только после перезапуска —
    /// сообщаем об этом прямо, а не рисуем «выдано».
    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func openInputMonitoringSettings() {
        openSettings("Privacy_ListenEvent")
    }

    func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func requestNotifications() async {
        _ = await prayer.notifications.requestAuthorization()
        refresh()
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            // Сборка из DerivedData регистрируется по временному пути —
            // честно показываем ошибку вместо мнимого успеха.
            loginItemError = error.localizedDescription
        }
        refresh()
    }

    func restartApp() {
        // Новый экземпляр не должен стартовать, пока этот процесс держит
        // aza.lock: иначе он сочтёт себя дубликатом и сразу завершится.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.05; done; exec /usr/bin/open -n \"$2\"",
            "aza-restart",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        guard (try? helper.run()) != nil else { return }
        exit(EXIT_SUCCESS)
    }

    private func openSettings(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
