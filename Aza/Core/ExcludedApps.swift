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

    /// Приложения, добавленные пользователем (спецификация §8.9): одна
    /// общая политика — ни коррекции раскладки, ни истории буфера.
    static let userDefaultsKey = "UserExcludedBundleIDs"
    static var userExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: userDefaultsKey) ?? [])
    }

    /// Запрещена ли автокоррекция раскладки в приложении. По решению
    /// владельца (28.08.2026) встроенный запрет остался только для
    /// менеджеров паролей: терминалы, IDE и лончеры исправляются как
    /// обычные приложения (при желании — в userExcluded). Системные
    /// диалоги (сохранение файла и т.п.) отдельно не детектируются:
    /// смена фокусного ОКНА рвёт контекст фразы, а точная сверка текста
    /// в replaceTypedText не даёт испортить чужое поле.
    static func isCorrectionDenied(bundleID: String) -> Bool {
        passwordManagers.contains(bundleID) || userExcluded.contains(bundleID)
    }
}
