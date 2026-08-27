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

    /// Фокусное окно системы — идентичность для разрыва контекста фразы
    /// при переключении окон (включая документы одного приложения и диалоги).
    static func focusedWindow() -> AXUIElement? {
        guard let element = focusedElement() else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXWindowAttribute as CFString,
            &window
        ) == .success,
              let window,
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    /// Элемент ведёт себя как текстовый: у него есть читаемый диапазон
    /// выделения. Надёжнее ролевого фильтра (Notes/браузеры/Electron отдают
    /// роли вне AXTextField/AXTextArea), и в отличие от полного снятия
    /// проверки не даёт печатать синтетикой в кнопки и списки.
    static func isTextLike(_ element: AXUIElement) -> Bool {
        selectedRange(of: element) != nil
    }

    static func insert(_ text: String, into element: AXUIElement) -> AXError {
        let directResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard directResult != .success else { return .success }

        guard isTextLike(element), postUnicode(text) else { return directResult }
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

    /// Процесс, которому принадлежит элемент. Сравнивать сами элементы
    /// через CFEqual нельзя: система возвращает НОВУЮ обёртку для того же
    /// поля, и проверка «то же поле» всегда проваливалась.
    static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    /// Позиция каретки (location схлопнутого выделения); nil — выделение
    /// не пустое или недоступно.
    static func caretPosition(of element: AXUIElement) -> Int? {
        guard let range = selectedRange(of: element), range.length == 0 else { return nil }
        return range.location
    }

    /// Текст в диапазоне без изменения выделения (параметризованный AX).
    private static func string(forRange range: CFRange, in element: AXUIElement) -> String? {
        var cfRange = range
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            value,
            &result
        ) == .success else { return nil }
        return result as? String
    }

    /// Хвостовой токен строки: непрерывный не-пробельный суффикс.
    static func trailingToken(of body: String) -> String {
        String(body.reversed().prefix { !$0.isWhitespace }.reversed())
    }

    /// Возвращает слово, которое пользователь напечатал, если системная
    /// автозамена подменила его между нажатием разделителя и этим вызовом
    /// (macOS не знает чеченского: «лар» → «лор»). Перед кареткой обязан
    /// стоять разделитель, а подменённый токен — отличаться от typed;
    /// иначе поле не трогается.
    static func restoreTypedWord(
        in element: AXUIElement,
        typed: String,
        delimiter: String
    ) -> Bool {
        guard let caretRange = selectedRange(of: element), caretRange.length == 0 else { return false }
        let caret = caretRange.location
        let lookback = min(caret, typed.count + delimiter.count + 12)
        guard lookback > delimiter.count,
              let recent = string(forRange: CFRange(location: caret - lookback,
                                                    length: lookback), in: element),
              recent.hasSuffix(delimiter) else { return false }

        let token = trailingToken(of: String(recent.dropLast(delimiter.count)))
        guard !token.isEmpty,
              token.lowercased() != typed.lowercased(),
              abs(token.count - typed.count) <= 3 else { return false }

        let replaceLength = token.count + delimiter.count
        guard caret >= replaceLength,
              setSelectedRange(CFRange(location: caret - replaceLength,
                                       length: replaceLength), in: element) else { return false }

        // Перечитываем выделение: между чтением и выделением поле могло
        // измениться — тогда откатываем каретку и выходим.
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextAttribute as CFString, &selected
        ) == .success,
              let actual = selected as? String,
              actual == token + delimiter else {
            _ = setSelectedRange(CFRange(location: caret, length: 0), in: element)
            return false
        }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            (matchingCase(of: actual, applyingTo: typed) + delimiter) as CFString
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
