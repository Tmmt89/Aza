import Foundation

/// Настройки коррекции чеченских слов.
///
/// По PLAN-chechen §3.3 опечаточная коррекция — самая рискованная функция,
/// поэтому она ВЫКЛЮЧЕНА по умолчанию. Воздержание при неоднозначности —
/// наоборот, ВКЛЮЧЕНО по умолчанию: пропущенное исправление лучше
/// подменённого слова чужого языка.
@MainActor
enum ChechenAutocorrect {

    /// Главный тумблер: исправление раскладки целиком. Включено по
    /// умолчанию — это основная функция приложения, но выключить её
    /// пользователь должен иметь возможность одним переключателем.
    static let layoutStorageKey = "LayoutCorrectionEnabled"

    /// Опечаточная автокоррекция: выключена по умолчанию.
    static let typoStorageKey = "ChechenTypoCorrectionEnabled"

    /// Воздержание при неоднозначности с чеченским словом: включено по умолчанию.
    static let ambiguityStorageKey = "ChechenAmbiguityAbstentionEnabled"

    static var isLayoutCorrectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: layoutStorageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: layoutStorageKey) }
    }

    static var isTypoCorrectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: typoStorageKey) }
        set { UserDefaults.standard.set(newValue, forKey: typoStorageKey) }
    }

    static var isAmbiguityAbstentionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: ambiguityStorageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: ambiguityStorageKey) }
    }
}
