import ApplicationServices
import CoreGraphics

enum TextInsertion {
    /// Marks synthetic events so the global word monitor ignores Aza's own input.
    static let syntheticEventMarker: Int64 = 0x415A_41

    static func focusedElement() -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    static func insert(_ text: String, into element: AXUIElement) -> AXError {
        let directResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard directResult != .success else { return .success }

        guard SecureFieldDetector.isTextInput(element), postUnicode(text) else { return directResult }
        return .success
    }

    /// Replaces the `expected.count` characters before the caret, but only if they
    /// still equal `expected` — the caret may have moved during the settle delay.
    static func replaceTypedText(
        in element: AXUIElement,
        expecting expected: String,
        with text: String
    ) -> Bool {
        guard var range = selectedRange(of: element),
              range.length == 0,
              range.location >= expected.count else { return false }

        let caret = range.location
        range.location -= expected.count
        range.length = expected.count
        guard setSelectedRange(range, in: element) else { return false }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        ) == .success,
              let actual = selected as? String,
              // Case-insensitive: apps auto-capitalize the first word of a
              // sentence between the keystroke and this read. Any other
              // difference means the text is not what the user typed.
              actual.lowercased() == expected.lowercased() else {
            // Put the caret back and do nothing rather than corrupt the field.
            _ = setSelectedRange(CFRange(location: caret, length: 0), in: element)
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            matchingCase(of: actual, applyingTo: text) as CFString
        ) == .success
    }

    /// Carries an auto-capitalized first letter over to the corrected text.
    static func matchingCase(of actual: String, applyingTo text: String) -> String {
        guard actual.first?.isUppercase == true,
              let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }

        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    private static func setSelectedRange(_ range: CFRange, in element: AXUIElement) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func postUnicode(_ text: String) -> Bool {
        let characters = Array(text.utf16)
        guard let source = CGEventSource(stateID: .privateState),
              !characters.isEmpty,
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }

        keyDown.flags = []
        keyUp.flags = []
        characters.withUnsafeBufferPointer { buffer in
            keyDown.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress!
            )
        }
        markAndPost(keyDown)
        markAndPost(keyUp)
        return true
    }

    private static func markAndPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }
}
