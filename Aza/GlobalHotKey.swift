import Carbon.HIToolbox
import Combine
import ApplicationServices
import AppKit
import CoreGraphics
import Dispatch

@MainActor
final class GlobalHotKey: ObservableObject {
    @Published private(set) var activationCount = 0
    @Published private(set) var registrationError: OSStatus?
    @Published private(set) var insertionStatus = "Ожидает проверки вставки"
    @Published private(set) var correctionCount = 0
    @Published private(set) var correctionStatus = "Ожидает проверки раскладки"
    @Published private(set) var inputMonitoringGranted = false

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var wordMonitor: Any?
    private var currentWord = ""

    private static let syntheticEventMarker: Int64 = 0x415A_41

    init() {
#if DEBUG
        assert(Self.correction(for: "ghbdtn") == "привет")
        assert(Self.correction(for: "hello") == nil)
#endif
        inputMonitoringGranted = CGPreflightListenEventAccess()
        if inputMonitoringGranted {
            startWordMonitor()
        }

        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let controller = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    controller.handleActivation()
                }
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        guard handlerStatus == noErr else {
            registrationError = handlerStatus
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x415A_4131, id: 1) // AZA1
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )

        if hotKeyStatus != noErr {
            registrationError = hotKeyStatus
        }
    }

    func requestInputMonitoring() {
        inputMonitoringGranted = CGRequestListenEventAccess()
        correctionStatus = inputMonitoringGranted
            ? "Input Monitoring разрешён"
            : "Включите Aza в Input Monitoring и перезапустите"
        if inputMonitoringGranted, wordMonitor == nil {
            startWordMonitor()
        }
    }

    private func handleActivation() {
        activationCount += 1

        guard AXIsProcessTrusted() else {
            insertionStatus = "Разрешите Aza управлять компьютером"
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }

        var value: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard focusResult == .success, let value else {
            insertionStatus = "Активное поле ввода не найдено"
            return
        }

        let element = value as! AXUIElement
        guard !isSecure(element) else {
            insertionStatus = "В защищённые поля Aza не вставляет"
            return
        }

        let insertResult = insert("Тест Aza", into: element)
        insertionStatus = insertResult == .success
            ? "«Тест Aza» вставлен"
            : "Поле не поддерживает прямую вставку (\(insertResult.rawValue))"
    }

    private func insert(_ text: String, into element: AXUIElement) -> AXError {
        let directResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        guard directResult != .success else { return .success }

        guard isTextInput(element), postUnicode(text) else { return directResult }
        return .success
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subrole
        ) == .success && subrole as? String == kAXSecureTextFieldSubrole as String
    }

    private func isTextInput(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &role
        ) == .success, let role = role as? String else {
            return false
        }
        return role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
    }

    private func startWordMonitor() {
        wordMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleKey(event)
            }
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.syntheticEventMarker else {
            return
        }

        // ponytail: TextEdit-only proof; widen with the application exclusion policy after the system path is proven.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            currentWord = ""
            return
        }

        if event.keyCode == UInt16(kVK_Delete) {
            if !currentWord.isEmpty {
                currentWord.removeLast()
            }
            return
        }

        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let characters = event.characters,
              !characters.isEmpty else {
            currentWord = ""
            return
        }

        for character in characters {
            if character.isLetter {
                currentWord.append(character)
            } else {
                finishWord(delimiter: String(character))
                currentWord = ""
            }
        }
    }

    private func finishWord(delimiter: String) {
        guard let corrected = Self.correction(for: currentWord) else { return }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
              let element = value as! AXUIElement?,
              isTextInput(element),
              !isSecure(element) else {
            correctionStatus = "Поле нельзя исправлять"
            return
        }

        let deleteCount = currentWord.count + delimiter.count
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self,
                  self.replaceTypedWord(
                    in: element,
                    deleteCount: deleteCount,
                    with: corrected + delimiter
                  ) else {
                self?.correctionStatus = "Не удалось заменить слово"
                return
            }
            self.correctionCount += 1
            self.correctionStatus = self.selectInputSource(language: "ru")
                ? "ghbdtn → привет; раскладка: RU"
                : "Слово исправлено, русская раскладка не найдена"
        }
    }

    private static func correction(for word: String) -> String? {
        word == "ghbdtn" ? "привет" : nil
    }

    private func selectInputSource(language: String) -> Bool {
        guard let source = TISCopyInputSourceForLanguage(language as CFString)?.takeRetainedValue() else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    private func replaceTypedWord(
        in element: AXUIElement,
        deleteCount: Int,
        with text: String
    ) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return false }

        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange,
              AXValueGetValue(axValue, .cfRange, &range),
              range.location >= deleteCount else { return false }

        range.location -= deleteCount
        range.length = deleteCount
        guard let selectedRange = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                selectedRange
              ) == .success else { return false }

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success
    }

    private func postUnicode(_ text: String) -> Bool {
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

    private func markAndPost(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
        event.post(tap: .cghidEventTap)
    }

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let handler {
            RemoveEventHandler(handler)
        }
        if let wordMonitor {
            NSEvent.removeMonitor(wordMonitor)
        }
    }
}
