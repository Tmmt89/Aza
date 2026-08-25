import Foundation

/// Настройка орфографической автокоррекции чеченских опечаток.
///
/// По PLAN-chechen §3.3 это самая рискованная функция, поэтому она
/// ВЫКЛЮЧЕНА ПО УМОЛЧАНИЮ и включается пользователем вручную.
@MainActor
enum ChechenAutocorrect {

    static let storageKey = "ChechenTypoCorrectionEnabled"

    /// Ложное исправление хуже пропущенной опечатки: значение по умолчанию — false.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: storageKey) }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }
}
