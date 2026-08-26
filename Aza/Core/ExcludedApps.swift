import Foundation

/// Политика исключений приложений (спецификация §6): где Aza никогда не
/// исправляет раскладку и не собирает буфер. Секьюрные поля отсекаются
/// отдельно (SecureFieldDetector) на уровне элемента, URL/email —
/// механикой ремапа (@ и / не ремапятся, домены не проходят словарную
/// валидацию).
///
/// ponytail: статичные списки; пользовательская настройка списка — этап
/// «исключения приложений» из спецификации (§ настройки).
enum ExcludedApps {

    /// Менеджеры паролей: ни коррекции, ни истории буфера.
    static let passwordManagers: Set<String> = [
        "com.agilebits.onepassword-osx",
        "com.agilebits.OnePassword7",
        "com.agilebits.BrowserExtension",
        "com.1password.1password",
        "net.antelle.keeweb",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.dashlane.Dashlane",
    ]

    /// Терминалы: команды и пути ломать нельзя.
    static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
    ]

    /// Редакторы кода и IDE: идентификаторы и код не трогаем; ручная
    /// коррекция горячей клавишей остаётся возможной (спецификация §6).
    static let codeEditorPrefixes: [String] = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.jetbrains.",
        "com.sublimetext.",
        "dev.zed.Zed",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.vscodium",
    ]

    /// Лончеры и Spotlight: запросы — команды, имена приложений и
    /// идентификаторы; ложное исправление хуже пропуска.
    static let launchers: Set<String> = [
        "com.apple.Spotlight",
        "com.runningwithcrayons.Alfred",
        "com.raycast.macos",
    ]

    /// Приложения, добавленные пользователем (спецификация §8.9): одна
    /// общая политика — ни коррекции раскладки, ни истории буфера.
    static let userDefaultsKey = "UserExcludedBundleIDs"
    static var userExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? [])
    }

    /// Запрещена ли автокоррекция раскладки в приложении. Системные
    /// диалоги (сохранение файла и т.п.) отдельно не детектируются:
    /// смена фокусного ОКНА рвёт контекст фразы, а точная сверка текста
    /// в replaceTypedText не даёт испортить чужое поле.
    static func isCorrectionDenied(bundleID: String) -> Bool {
        if passwordManagers.contains(bundleID) { return true }
        if terminals.contains(bundleID) { return true }
        if launchers.contains(bundleID) { return true }
        if userExcluded.contains(bundleID) { return true }
        return codeEditorPrefixes.contains { bundleID.hasPrefix($0) }
    }
}
