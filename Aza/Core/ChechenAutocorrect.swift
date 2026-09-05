import Foundation

/// Настройки коррекции чеченских слов.
///
/// По PLAN-chechen §3.3 опечаточная коррекция — самая рискованная функция,
/// поэтому она ВЫКЛЮЧЕНА по умолчанию. Воздержание при неоднозначности —
/// наоборот, ВКЛЮЧЕНО по умолчанию: пропущенное исправление лучше
/// подменённого слова чужого языка.
@MainActor
enum ChechenAutocorrect {

    /// Исправление раскладки: выключено по умолчанию, независимо от опечаток.
    static let layoutStorageKey = "LayoutCorrectionEnabled"

    /// Опечаточная автокоррекция: выключена по умолчанию.
    static let typoStorageKey = "ChechenTypoCorrectionEnabled"

    /// Воздержание при неоднозначности с чеченским словом: включено по умолчанию.
    static let ambiguityStorageKey = "ChechenAmbiguityAbstentionEnabled"

    /// Обратное направление — кириллица → английский («ыфдфв» → «salad»).
    /// Включено по умолчанию, но отключаемо отдельно: это самое рискованное
    /// из направлений раскладки.
    static let latinizationStorageKey = "CyrillicToLatinEnabled"

    static var isLayoutCorrectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: layoutStorageKey) as? Bool ?? false }
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

    static var isLatinizationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: latinizationStorageKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: latinizationStorageKey) }
    }

    /// Активный перехват (CGEventTap): разделитель задерживается, слово
    /// заменяется ДО его вставки — ноль гонок и работа в любых полях.
    /// Выключено по умолчанию: режим меняет путь всего ввода, включать
    /// осознанно (defaults write + перезапуск).
    static let activeTapStorageKey = "ActiveEventTapEnabled"

    static var isActiveTapEnabled: Bool {
        get { UserDefaults.standard.object(forKey: activeTapStorageKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: activeTapStorageKey) }
    }
}
