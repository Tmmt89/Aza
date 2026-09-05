import AppKit
import Carbon.HIToolbox

/// Пользовательская горячая клавиша (§5.1, §10 «Основные»).
///
/// Хранится кодом КЛАВИШИ, а не символом: на кириллической раскладке та
/// же физическая клавиша даёт другую букву, и сочетание не должно
/// «переезжать» вместе с языком ввода.
struct HotKeyBinding: Codable, Equatable {
    var keyCode: UInt32
    /// Модификаторы в терминах Carbon (cmdKey, shiftKey, optionKey, controlKey).
    var modifiers: UInt32

    static let dictationKey = "HotKey.Dictation"
    static let clipboardKey = "HotKey.Clipboard"
    static let phrasesKey = "HotKey.Phrases"

    static let dictationDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey))
    static let clipboardDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | shiftKey))
    static let phrasesDefault = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | shiftKey))

    static func load(_ key: String, fallback: HotKeyBinding) -> HotKeyBinding {
        guard let data = UserDefaults.standard.data(forKey: key),
              let binding = try? JSONDecoder().decode(HotKeyBinding.self, from: data)
        else { return fallback }
        return binding
    }

    func save(_ key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Сохраняем назначение только вместе с работающей регистрацией.
    @MainActor
    func save(_ key: String, registering: () -> OSStatus?) -> String? {
        if let problem = phraseSelectionConflict(for: key) { return problem }
        let previous = UserDefaults.standard.object(forKey: key)
        save(key)
        guard let status = registering() else { return nil }
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let problem = registrationError(status)
        if let restoreStatus = registering() {
            return problem + " Прежнее сочетание тоже недоступно (ошибка \(restoreStatus))."
        }
        return problem + " Прежнее сочетание сохранено."
    }

    /// Shift всегда выбирает вариант, даже если он входит в сочетание открытия.
    var phraseDigitModifiers: [UInt32] {
        var result: [UInt32] = []
        for base in [UInt32(optionKey), modifiers & ~UInt32(shiftKey)] {
            for value in [base, base | UInt32(shiftKey)] where !result.contains(value) {
                result.append(value)
            }
        }
        return result
    }

    static let phraseDigitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                 kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8,
                                 kVK_ANSI_9, kVK_ANSI_0].map(UInt32.init)

    /// Цифры фраз регистрируются позже, поэтому Carbon ещё не видит конфликт
    /// при сохранении настройки. Проверяем оба порядка назначения.
    func phraseSelectionConflict(for key: String) -> String? {
        guard [Self.dictationKey, Self.clipboardKey, Self.phrasesKey].contains(key) else { return nil }
        let phrases = key == Self.phrasesKey ? self : Self.load(Self.phrasesKey, fallback: .phrasesDefault)
        let bindings = key == Self.phrasesKey ? [self,
            Self.load(Self.clipboardKey, fallback: .clipboardDefault),
            Self.load(Self.dictationKey, fallback: .dictationDefault)] : [self]
        guard let conflict = bindings.first(where: {
            Self.phraseDigitKeys.contains($0.keyCode) && phrases.phraseDigitModifiers.contains($0.modifiers)
        }) else { return nil }
        return "Сочетание \(conflict.display) нужно для выбора фразы по цифре. Выберите другое сочетание."
    }

    func registrationError(_ status: OSStatus) -> String {
        switch status {
        case OSStatus(eventHotKeyExistsErr):
            return "Сочетание \(display) уже занято. Выберите другое."
        case OSStatus(permErr):
            return "Для клавиши \(display) разрешите Aza «Универсальный доступ» в настройках macOS."
        default:
            return "Не удалось назначить \(display) (ошибка \(status)). Выберите другое сочетание."
        }
    }

    /// Человеческая запись сочетания: ⌃⇧D.
    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(keyCode)
    }

    /// Есть ли хоть один модификатор: без него глобальный хоткей перехватит
    /// обычный набор текста.
    var hasModifier: Bool {
        modifiers & UInt32(cmdKey | shiftKey | optionKey | controlKey) != 0
    }

    /// Клавиши-модификаторы: keyCode → флаг NSEvent. Такие клавиши не дают
    /// keyDown и не регистрируются через Carbon — ловятся монитором
    /// flagsChanged (ModifierKeyMonitor). Лево/право различимы по keyCode.
    static let modifierFlagByKeyCode: [UInt16: NSEvent.ModifierFlags] = [
        UInt16(kVK_Function): .function,
        UInt16(kVK_Control): .control, UInt16(kVK_RightControl): .control,
        UInt16(kVK_Option): .option, UInt16(kVK_RightOption): .option,
        UInt16(kVK_Shift): .shift, UInt16(kVK_RightShift): .shift,
        UInt16(kVK_Command): .command, UInt16(kVK_RightCommand): .command,
    ]

    /// Одиночная клавиша-модификатор (Fn, ⌃, ⌥, ⇧, ⌘).
    var isModifierOnly: Bool {
        guard let code = UInt16(exactly: keyCode) else { return false }
        return Self.modifierFlagByKeyCode[code] != nil && modifiers == 0
    }

    /// Перевод CGEvent в Carbon-модификаторы (матчинг хоткеев в tap'е).
    static func carbonModifiers(fromCG flags: CGEventFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.maskCommand) { result |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { result |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { result |= UInt32(optionKey) }
        if flags.contains(.maskControl) { result |= UInt32(controlKey) }
        return result
    }

    /// Перевод NSEvent в Carbon-модификаторы.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    /// Подпись клавиши по её коду — независимо от текущей раскладки.
    static func keyName(_ code: UInt32) -> String {
        let names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Escape: "Esc", kVK_Tab: "⇥",
            kVK_Function: "🌐 fn",
            kVK_Control: "левый ⌃", kVK_RightControl: "правый ⌃",
            kVK_Option: "левая ⌥", kVK_RightOption: "правая ⌥",
            kVK_Shift: "левый ⇧", kVK_RightShift: "правый ⇧",
            kVK_Command: "левый ⌘", kVK_RightCommand: "правый ⌘",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        ]
        return names[Int(code)] ?? "Клавиша \(code)"
    }
}
