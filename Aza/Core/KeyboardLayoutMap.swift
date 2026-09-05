import Carbon.HIToolbox
import Foundation

/// Character mappings between the user's installed keyboard layouts, read from
/// the system with UCKeyTranslate instead of being hardcoded: layouts disagree
/// about punctuation. macOS "Russian" puts ё on the backslash key, while the
/// Windows-style ЙЦУКЕН puts it on the backtick.
@MainActor
enum KeyboardLayoutMap {
    private static var tables: [String: [Character: Character]] = [:]
    private static var punctuation: Set<Character>?

    /// Maps every character of the `source` layout to the character produced by
    /// the same physical key in the `target` layout. Nil when either language
    /// has no installed keyboard layout.
    static func table(from source: String, to target: String) -> [Character: Character]? {
        observeLayoutChangesOnce()
        let cacheKey = "\(source)>\(target)"
        if let cached = tables[cacheKey] { return cached }

        guard let sourceLayout = layoutData(for: source),
              let targetLayout = layoutData(for: target) else { return nil }

        var table: [Character: Character] = [:]
        for keyCode in UInt16(0)...50 {
            for shift in [false, true] {
                guard let typed = character(keyCode, shift: shift, in: sourceLayout),
                      let mapped = character(keyCode, shift: shift, in: targetLayout),
                      typed != mapped,
                      // Keys where neither side is a letter (` -> ], ^ -> ,) are
                      // punctuation in both layouts and never part of a word.
                      typed.isLetter || mapped.isLetter else { continue }
                table[typed] = mapped
            }
        }

        guard !table.isEmpty else { return nil }
        tables[cacheKey] = table
        return table
    }

    /// Non-letter characters that carry letters in the other layout, so they are
    /// part of a word rather than a delimiter (б and ю sit on , and .).
    static func wordPunctuation() -> Set<Character> {
        if let punctuation { return punctuation }
        var set: Set<Character> = ["1"] // palochka look-alike
        for language in ["ru", "ce"] {
            guard let table = table(from: "en", to: language) else { continue }
            set.formUnion(table.keys.filter { !$0.isLetter })
        }
        punctuation = set
        return set
    }

    /// Call when the set of installed layouts changes.
    static func invalidate() {
        tables.removeAll()
        punctuation = nil
    }

    /// Смена набора/выбора раскладок инвалидирует кэш сама: иначе таблицы
    /// жили до перезапуска, и установленная на лету раскладка (или смена
    /// «Русская» ↔ «Русская — ПК») отдавала устаревшие ремапы. Пересборка
    /// ленивая и дешёвая (2×51 UCKeyTranslate).
    private static var observing = false
    private static func observeLayoutChangesOnce() {
        guard !observing else { return }
        observing = true
        for case let name? in [kTISNotifyEnabledKeyboardInputSourcesChanged,
                               kTISNotifySelectedKeyboardInputSourceChanged] {
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(name as String),
                object: nil, queue: .main
            ) { _ in
                azaAssumeMainUnchecked { invalidate() }
            }
        }
    }

    private static func layoutData(for language: String) -> CFData? {
        guard let source = TISCopyInputSourceForLanguage(language as CFString)?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }

    private static func character(_ keyCode: UInt16, shift: Bool, in layout: CFData) -> Character? {
        guard let bytes = CFDataGetBytePtr(layout) else { return nil }
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { pointer in
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            guard UCKeyTranslate(
                pointer,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                shift ? 2 : 0, // (shiftKey >> 8) & 0xFF
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                4,
                &length,
                &characters
            ) == noErr, length == 1 else { return nil }
            return String(utf16CodeUnits: characters, count: 1).first
        }
    }
}
