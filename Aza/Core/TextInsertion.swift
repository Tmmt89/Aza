import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

enum TextInsertion {
    /// Marks synthetic events so the global word monitor ignores Aza's own input.
    static let syntheticEventMarker: Int64 = 0x415A_41

    static func focusedElement() -> AXUIElement? {
        if let element = focusedElement(of: AXUIElementCreateSystemWide()) {
            return element
        }
        // Electron/Chromium (VS Code, Slack…) не строит AX-дерево, пока
        // ассистивная технология не заявит о себе (AXManualAccessibility),
        // и фокус отдаёт только через элемент ПРИЛОЖЕНИЯ — системный
        // AXFocusedUIElement остаётся пустым даже после пробуждения.
        // Другие приложения атрибут молча отвергают. Дерево строится
        // асинхронно: первое слово после пробуждения может пропасть,
        // дальше элемент находится.
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        return focusedElement(of: appElement)
    }

    private static func focusedElement(of container: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            container,
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
        return window(of: element)
    }

    /// Окно элемента (nil — атрибут недоступен: webview, системные поля).
    static func window(of element: AXUIElement) -> AXUIElement? {
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
        let before = selectedRange(of: element)
        let directResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        if directResult == .success {
            // Chromium (Claude Desktop, webview) отвечает success, ничего
            // не применив. Настоящая запись меняет выделение синхронно:
            // вставка сдвигает каретку, замена схлопывает выделение
            // (проверено живьём на TextEdit и Claude Desktop). Выделение
            // не изменилось — это no-op: отдаём отказ, чтобы вызывающие
            // ушли в свои ⌘V-фолбэки (текст у всех уже в буфере).
            guard !text.isEmpty, let before,
                  let after = selectedRange(of: element),
                  after.location == before.location,
                  after.length == before.length else { return .success }
            azaDebugLog("Aza: insert fake success loc=\(before.location) len=\(before.length)")
            return .cannotComplete
        }

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
              range.location >= expected.count else {
            azaDebugLog("Aza: replace fail stage=range \(selectedRange(of: element).map { "loc=\($0.location) len=\($0.length)" } ?? "nil") need=\(expected.count)")
            return false
        }

        let caret = range.location
        range.location -= expected.count
        range.length = expected.count

        // Сверка ДО выделения параметризованным чтением: в Chromium-webview
        // (Claude-чат VS Code) чтение выделенного текста возвращает пустоту,
        // а чтение по диапазону работает. nil — атрибут не поддержан,
        // тогда сверяет чтение выделенного ниже.
        let preread = string(forRange: range, in: element)
        if let preread, preread.lowercased() != expected.lowercased() {
            azaDebugLog("Aza: replace fail stage=preverify got=\(preread.count) want=\(expected.count)")
            return false
        }

        guard setSelectedRange(range, in: element) else {
            azaDebugLog("Aza: replace fail stage=setRange loc=\(range.location) len=\(range.length)")
            return false
        }

        // Выделение могло молча не примениться (Chromium возвращает успех
        // и для no-op): сверяем фактический диапазон, иначе запись ниже
        // ВСТАВИТ текст в каретку вместо замены слова.
        guard let applied = selectedRange(of: element),
              applied.location == range.location,
              applied.length == range.length else {
            azaDebugLog("Aza: replace fail stage=selection")
            _ = setSelectedRange(CFRange(location: caret, length: 0), in: element)
            return false
        }

        var selected: CFTypeRef?
        AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selected
        )
        let actual = selected as? String
        // Case-insensitive: apps auto-capitalize the first word of a
        // sentence between the keystroke and this read. Any other
        // difference means the text is not what the user typed. Пустое
        // чтение выделенного прощается, если сверка по диапазону прошла.
        guard actual?.lowercased() == expected.lowercased()
                || (preread != nil && (actual ?? "").isEmpty) else {
            azaDebugLog("Aza: replace fail stage=verify got=\(actual?.count ?? -1) want=\(expected.count)")
            // Put the caret back and do nothing rather than corrupt the field.
            _ = setSelectedRange(CFRange(location: caret, length: 0), in: element)
            return false
        }

        let sample = (actual?.isEmpty == false ? actual! : preread ?? expected)
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            matchingCase(of: sample, applyingTo: text) as CFString
        ) == .success else {
            azaDebugLog("Aza: replace fail stage=write")
            _ = setSelectedRange(CFRange(location: caret, length: 0), in: element)
            return false
        }

        // Пост-проверка для webview: запись могла «успешно» не примениться.
        if preread != nil,
           let written = string(forRange: CFRange(location: range.location,
                                                  length: text.count), in: element),
           written.lowercased() != text.lowercased() {
            azaDebugLog("Aza: replace fail stage=postverify")
            _ = setSelectedRange(CFRange(location: caret, length: 0), in: element)
            return false
        }
        return true
    }

    /// Сверка перед кареткой с допуском на быстрый набор: за задержку
    /// замены пользователь успевает напечатать ещё буквы, и expected
    /// оказывается не вплотную к каретке. Возвращает «хвост» — то, что
    /// напечатано ПОСЛЕ expected (пустой, если каретка сразу за ним);
    /// nil — expected перед кареткой не найден, сверка невозможна.
    static func typedTail(after expected: String, in element: AXUIElement,
                          maxTail: Int) -> String? {
        guard let range = selectedRange(of: element), range.length == 0 else { return nil }
        let lookback = min(range.location, expected.count + maxTail)
        guard lookback >= expected.count,
              let window = string(forRange: CFRange(location: range.location - lookback,
                                                    length: lookback), in: element),
              let found = window.range(of: expected,
                                       options: [.backwards, .caseInsensitive])
        else { return nil }
        return String(window[found.upperBound...])
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

    /// Слово непосредственно перед кареткой — цель ручного исправления ⌘⇧A.
    static func tokenBeforeCaret(in element: AXUIElement, maxLength: Int = 24) -> String? {
        guard let range = selectedRange(of: element), range.length == 0 else { return nil }
        let lookback = min(range.location, maxLength)
        guard lookback > 0,
              let recent = string(forRange: CFRange(location: range.location - lookback,
                                                    length: lookback), in: element) else { return nil }
        return trailingToken(of: recent)
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

    /// Синтетический ⌘V — последний рубеж для приложений, чьё AX-дерево не
    /// принимает ни прямую запись, ни синтетический юникод (Electron до
    /// пробуждения). Текст обязан уже лежать в буфере обмена. Флаги события
    /// выставляются явно: физически зажатые модификаторы (правая ⌥ в
    /// hold-режиме фраз) на посланное событие не переносятся.
    static func postPasteCommand() -> Bool {
        // Защищённый ввод включён — фокус в парольном поле (системном или
        // корректного приложения): слепой ⌘V туда запрещён. AX-слепые
        // webview этот guard не задевает — они защищённый ввод не включают.
        // Остаточный риск (кастомное парольное поле БЕЗ SecureEventInput в
        // AX-слепом приложении) закрывается только полным fail-closed — это
        // отключило бы webview-фолбэк целиком; решение за владельцем.
        guard !IsSecureEventInputEnabled() else {
            azaDebugLog("Aza: paste blocked — secure event input active")
            return false
        }
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source,
                                    virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        markAndPost(keyDown)
        markAndPost(keyUp)
        return true
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

    /// AX-картинка поля ложная: его значение не содержит набранного слова.
    /// Chromium-webview (Claude-чат VS Code) подсовывает вместо содержимого
    /// aria-подсказку — настоящий текст такого поля через AX недостижим.
    /// Нечитаемое значение тоже считается ложным.
    static func valueHidesTypedWord(in element: AXUIElement, typed: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value
        ) == .success,
              let text = value as? String else {
            azaDebugLog("Aza: axValue unreadable -> fake view")
            return true
        }
        let hides = !text.localizedCaseInsensitiveContains(typed)
        azaDebugLog("Aza: axValue len=\(text.count) hidesTyped=\(hides ? 1 : 0)")
        return hides
    }

    /// Punto-style последний шанс для полей, где AX-замена не применяется:
    /// стереть слово (и хвост быстрого набора) backspace-ами и перепечатать
    /// исправление с хвостом синтетикой. Вызывать только после сверки
    /// typedTail либо когда valueHidesTypedWord подтвердил, что AX-картинка
    /// поля ложная и сверить нечем.
    /// ponytail: буквы, напечатанные МЕЖДУ сверкой и backspace-ами,
    /// по-прежнему съедаются — окно гонки сжато, но не закрыто (как у Punto).
    ///
    /// `verifying` — элемент, против которого шла сверка: синтетика летит
    /// в СФОКУСИРОВАННОЕ поле, и если за задержку фокус ушёл в другое окно
    /// или поле, backspace-ы стёрли бы чужой текст. Проверяем, что фокус
    /// всё ещё на том же элементе (pid + совпадение диапазона выделения:
    /// CFEqual для AX-обёрток не работает). nil — элемента не было и при
    /// сверке (активный режим), проверять не с чем.
    static func retypeWord(typed: String, delimiter: String, corrected: String,
                           tail: String, verifying element: AXUIElement? = nil) -> Bool {
        if let element {
            // pid строго: нечитаемый pid с любой стороны — отказ, а не
            // совпадение nil == nil.
            guard let focused = focusedElement(),
                  let focusedPid = processID(of: focused),
                  focusedPid == processID(of: element),
                  windowsMatch(focused, element),
                  selectedRangesMatch(focused, element) else {
                azaDebugLog("Aza: retype abort — focus moved")
                return false
            }
            // Сфокусированное поле обязано ПОКАЗЫВАТЬ стираемый текст перед
            // кареткой: два поля одного окна с совпавшей позицией каретки
            // различаются содержимым. Диапазон читается, но не схлопнут или
            // короче стираемого — состояние поля не то, что сверялось: отказ.
            // Совсем нечитаемое поле сверяется только pid/окном/диапазоном —
            // fakeView-случай, где сверить нечем (осознанный остаток риска).
            let deletable = typed + delimiter + tail
            if !deletable.isEmpty, let range = selectedRange(of: focused) {
                guard range.length == 0, range.location >= deletable.count else {
                    azaDebugLog("Aza: retype abort — caret state")
                    return false
                }
                // Диапазон читается, а текст по нему — нет: сверить нечем,
                // и это уже НЕ fakeView (у того и диапазон недоступен) —
                // отказ, ложное стирание хуже пропущенного исправления.
                guard let before = string(
                    forRange: CFRange(location: range.location - deletable.count,
                                      length: deletable.count), in: focused),
                      before.lowercased() == deletable.lowercased() else {
                    azaDebugLog("Aza: retype abort — text mismatch")
                    return false
                }
            }
        }
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        for _ in 0..<(typed.count + delimiter.count + tail.count) {
            guard let down = CGEvent(keyboardEventSource: source,
                                     virtualKey: CGKeyCode(kVK_Delete), keyDown: true),
                  let up = CGEvent(keyboardEventSource: source,
                                   virtualKey: CGKeyCode(kVK_Delete), keyDown: false) else {
                return false
            }
            down.flags = []
            up.flags = []
            markAndPost(down)
            markAndPost(up)
        }
        return postUnicode(corrected + delimiter + tail)
    }

    /// Окна совпадают (CFEqual для окон работает, в отличие от полей;
    /// оба nil — совпадение: webview окно не отдаёт).
    private static func windowsMatch(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        switch (window(of: a), window(of: b)) {
        case (nil, nil): return true
        case let (x?, y?): return CFEqual(x, y)
        default: return false
        }
    }

    /// Диапазоны выделения совпадают (оба нечитаемы — тоже совпадение:
    /// «глухой» webview не отдаёт диапазон ни старой, ни новой обёртке).
    private static func selectedRangesMatch(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        let ra = selectedRange(of: a)
        let rb = selectedRange(of: b)
        return ra?.location == rb?.location && ra?.length == rb?.length
    }

    private static func markAndPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }
}
