import Carbon.HIToolbox

enum InputSourceSwitcher {
    /// Switches the keyboard layout. Returns nil on success, otherwise a
    /// human-readable reason (shown in the panel instead of a raw OSStatus).
    static func select(language: String) -> String? {
        guard let source = TISCopyInputSourceForLanguage(language as CFString)?.takeRetainedValue() else {
            return "раскладка \(language.uppercased()) не найдена"
        }

        let status = TISSelectInputSource(source)
        guard status == noErr else {
            return "система отклонила переключение (\(status))"
        }

        // macOS can remember a layout per document; verify the switch stuck.
        guard currentID() == identifier(of: source) else {
            return "macOS вернула прежнюю раскладку"
        }
        return nil
    }

    static func currentID() -> String? {
        TISCopyCurrentKeyboardInputSource().flatMap { identifier(of: $0.takeRetainedValue()) }
    }

    private static func identifier(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
