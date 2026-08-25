import Foundation

/// Настройки коррекции чеченских слов.
///
/// По PLAN-chechen §3.3 опечаточная коррекция — самая рискованная функция,
/// поэтому она ВЫКЛЮЧЕНА по умолчанию. Воздержание при неоднозначности —
/// наоборот, ВКЛЮЧЕНО по умолчанию: пропущенное исправление лучше
/// подменённого слова чужого языка.
@MainActor
enum ChechenAutocorrect {

    /// Опечаточная автокоррекция: выключена по умолчанию.
    static let typoStorageKey = "ChechenTypoCorrectionEnabled"

    /// Воздержание при неоднозначности с чеченским словом: включено по умолчанию.
    static let ambiguityStorageKey = "ChechenAmbiguityAbstentionEnabled"

    static var isTypoCorrectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: typoStorageKey) }
        set { UserDefaults.standard.set(newValue, forKey: typoStorageKey) }
    }

    static var isAmbiguityAbstentionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: ambiguityStorageKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: ambiguityStorageKey) }
    }
}
