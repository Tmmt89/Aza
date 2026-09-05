import AppKit
import AVFoundation
import ApplicationServices
import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// Знакомство при первом запуске и постоянное окно настроек.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {

    static let completedKey = OnboardingProgress.completedKey

    private var window: NSWindow?
    private let model: SetupModel

    init(model: SetupModel) {
        self.model = model
    }

    /// Кнопка закрытия и ⌘W идут сюда: окно сперва уезжает вверх, и
    /// только потом закрывается по-настоящему (close() делегата не зовёт).
    /// Флаг гасит повторные ⌘W во время анимации — второй slideOut
    /// стартовал бы с полдороги и сдвинул сохранённый кадр окна.
    private var isSlidingOut = false

    // Диагностика «настройки открываются за краем экрана»: окно
    // оказывалось на X≈1600 при центре 524, а код X не трогает вовсе —
    // лог покажет, кто и когда его двигает.
    func windowDidMove(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        azaDebugLog("Aza: SetupWindow moved frame=\(w.frame)")
    }

    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        azaDebugLog("Aza: SetupWindow resized frame=\(w.frame)")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSlidingOut else { return false }
        isSlidingOut = true
        sender.resignKey()
        sender.slideOut { [weak self] in
            self?.isSlidingOut = false
            sender.close()
        }
        return false
    }

    /// Показывается сама только при первом запуске; дальше — по команде
    /// из меню.
    func showIfFirstRun() {
        model.onboarding.restore()
        guard !model.onboarding.completed else { return }
        show(onboarding: true)
    }

    func show(onboarding: Bool = false) {
        model.showsOnboarding = onboarding
        azaDebugLog("Aza: SetupWindow.show, existing=\(window == nil ? 0 : 1)")
        // Профиль по умолчанию считаем ДО показа: переключатель должен
        // сразу стоять на скачанной или рекомендованной модели.
        DictationController.seedDefaultProfileIfNeeded()
        model.refresh()
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            // AzaSlidingWindow отключает системный constrain (ради полёта
            // за кромку), поэтому уехавший кадр никто не возвращает —
            // окно «открывалось» целиком за краем экрана. Не на экране —
            // в центр.
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame,
               !visible.contains(window.frame) {
                azaDebugLog("Aza: SetupWindow off-screen frame=\(window.frame), recenter")
                window.center()
            }
            // Без slideIn: первый показ за кромкой замораживает у окна
            // кликабельную форму там же — все кнопки «не нажимаются».
            window.makeKeyAndOrderFront(nil)
            forceKeyAppearance(window)
            resyncServerFrame(window)
            azaDebugLog("Aza: SetupWindow shown frame=\(window.frame)")
            return
        }
        let content = NSHostingView(rootView: SetupView(model: model))
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? CGSize(width: 1280, height: 800)
        let size = CGSize(width: min(820, visible.width - 40),
                          height: min(680, visible.height - 60))
        // AzaSlidingWindow: обычный NSWindow прижимался бы constrain'ом
        // к экрану и не смог бы улететь за верхнюю кромку при закрытии.
        let window = AzaSlidingWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки Aza"
        window.contentMinSize = CGSize(width: 700, height: 560)
        window.isReleasedWhenClosed = false
        // Тёмная сцена без системной полосы: окно — часть продукта,
        // а не стандартный диалог настроек.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = NSColor(red: 14 / 255, green: 14 / 255,
                                         blue: 16 / 255, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = content
        window.setContentSize(size)
        // center() после setContentSize: центровка по ещё не финальному
        // кадру оставляла окно со смещением.
        window.center()
        window.delegate = self
        self.window = window
        // Приложение живёт в меню-баре: без явной активации окно
        // откроется без фокуса, и кнопки будут «не нажиматься».
        NSApp.activate(ignoringOtherApps: true)
        // Без slideIn (см. выше): показ сразу на месте.
        window.makeKeyAndOrderFront(nil)
        forceKeyAppearance(window)
        resyncServerFrame(window)
        azaDebugLog("Aza: SetupWindow shown frame=\(window.frame)")
    }

    /// Система отклоняет makeKey у вечно неактивного приложения (AppKit
    /// роняет и активирующий клик — память aza-island-clicks), и окно
    /// рисуется блёкло: серые контролы, ни рамки фокуса, ни каретки.
    /// becomeKey() принудительно включает key-вид с самого показа.
    /// isKeyWindow остаётся системным: скрытое окно не должно объявлять
    /// себя получателем клавиш после закрытия настроек.
    private func forceKeyAppearance(_ window: NSWindow) {
        window.becomeKey()
    }

    /// Перетаскивание окна на этой macOS обрабатывает WindowServer, а
    /// события до приложения не доходят (память aza-island-clicks) —
    /// поверхность уезжает, модельный кадр застревает, и клики
    /// пересылаются мимо. Сдвиг на 1 пт и обратно заставляет сервер
    /// вернуть поверхность к модельному кадру (приём из slideIn).
    private func resyncServerFrame(_ window: NSWindow) {
        let frame = window.frame
        window.setFrame(frame.offsetBy(dx: 0, dy: 1), display: false)
        window.setFrame(frame, display: true)
    }
}

/// Состояние разрешений. Обновляется при каждой активации приложения:
/// Accessibility и Input Monitoring выдаются ВНЕ процесса, и узнать об
/// этом можно только переспросив систему.
@MainActor
final class SetupModel: ObservableObject {
    @Published var showsOnboarding = false
    let onboarding = OnboardingProgress()
    @Published private(set) var axTrusted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoring = CGPreflightListenEventAccess()
    @Published private(set) var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    @Published private(set) var loginItem: SMAppService.Status = .notRegistered
    @Published private(set) var loginItemError: String?
    @Published var clipboardHotKeyError: String?
    @Published var phrasesHotKeyError: String?

    let prayer: PrayerStore
    let dictation: DictationController
    /// Перерегистрация сочетаний буфера и фраз: хоткеями владеет
    /// IslandStore, замыкания подставляются в AzaApp.
    var rebindClipboardHotKey: () -> OSStatus? = { OSStatus(unimpErr) }
    var refreshInputAccess: () -> Void = {}
    var rebindPhrasesHotKey: () -> OSStatus? = { OSStatus(unimpErr) }
    /// «Очистить историю» (§8.7): избранное сохраняется. Историей владеет
    /// IslandStore — замыкание подставляется в AzaApp, как ребинды выше.
    var clearClipboardHistory: () -> Void = {}
    private var cancellables: Set<AnyCancellable> = []

    init(prayer: PrayerStore, dictation: DictationController) {
        self.prayer = prayer
        self.dictation = dictation
        NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // SwiftUI не видит вложенные ObservableObject: без форварда прогресс
        // загрузки модели замерзал, а busy-флаг в DataSheet устаревал и
        // разрешал удалить модели под живой диктовкой.
        for publisher in [dictation.objectWillChange, prayer.objectWillChange,
                          onboarding.objectWillChange] {
            publisher
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
        refresh()
    }

    func refresh() {
        refreshInputAccess()
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

    func requestMicrophone() {
        Task {
            await dictation.requestMicrophoneAccess()
            refresh()
        }
    }

    /// Кнопка «Разрешить» не только спрашивает систему, но и ВКЛЮЧАЕТ
    /// уведомления: setNotifications — единственный путь, который пишет
    /// PrayerNotificationsEnabled и планирует расписание. Раньше вызывался
    /// только requestAuthorization, и функция была невключаемой из UI.
    func requestNotifications() async {
        await prayer.setNotifications(enabled: true)
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

}
