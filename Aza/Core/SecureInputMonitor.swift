import AppKit
import Carbon.HIToolbox
import Combine

/// Детект «залипшего» Secure Event Input (приём Handy, MIT): когда любой
/// процесс включает защищённый ввод (Terminal → Secure Keyboard Entry,
/// зависший loginwindow), CGEventTap и NSEvent-мониторы перестают получать
/// клавиши — исправление раскладки и стоп-клавиши диктовки молча умирают,
/// а пользователь видит «не работает» без объяснений.
///
/// Мгновенные включения (поле пароля в фокусе) — норма и не показываются:
/// предупреждение появляется только после sustainedSeconds непрерывного
/// включения и само уходит, когда защищённый ввод выключился.
@MainActor
final class SecureInputMonitor: ObservableObject {
    /// nil — всё в порядке; строка — предупреждение для меню статус-бара.
    @Published private(set) var warning: String?

    private var timer: Timer?
    private var enabledSince: Date?
    /// Поле пароля держит защищённый ввод секунды; «залипание» — дольше.
    private static let sustainedSeconds: TimeInterval = 15
    private static let pollSeconds: TimeInterval = 5

    /// Старт сразу: Scene не имеет .onAppear (§8.7), а монитор должен
    /// работать независимо от открытий панели меню.
    init() {
        start()
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollSeconds,
                                     repeats: true) { [weak self] _ in
            azaAssumeMainUnchecked { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        enabledSince = nil
        warning = nil
    }

    private func poll() {
        guard IsSecureEventInputEnabled() else {
            enabledSince = nil
            if warning != nil {
                warning = nil
                azaDebugLog("Aza: secure input cleared")
            }
            return
        }
        let since = enabledSince ?? Date()
        enabledSince = since
        guard Date().timeIntervalSince(since) >= Self.sustainedSeconds,
              warning == nil else { return }
        let culprit = Self.culpritName().map { " («\($0)»)" } ?? ""
        warning = "Другое приложение\(culprit) включило защищённый ввод — "
            + "исправление раскладки и стоп-клавиши диктовки не работают, "
            + "пока оно его не выключит"
        azaDebugLog("Aza: secure input sustained")
    }

    /// Кто держит защищённый ввод: pid из сессионного словаря CG. API
    /// ненадёжен (pid бывает неверным или отсутствует — задокументировано
    /// в Handy) — имя лишь дополняет предупреждение, без него тоже работаем.
    private static func culpritName() -> String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let pid = session["kCGSSessionSecureInputPID"] as? Int32,
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.localizedName
    }
}
