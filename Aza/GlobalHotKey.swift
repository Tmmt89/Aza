import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Combine

/// Coordinator: wires the hot key, the word monitor and text insertion together
/// and exposes status for the menu panel. Lives for the whole app lifetime.
@MainActor
final class GlobalHotKey: ObservableObject {
    @Published private(set) var activationCount = 0
    @Published private(set) var registrationError: OSStatus?
    @Published private(set) var insertionStatus = "Ожидает проверки вставки"
    @Published private(set) var correctionCount = 0
    @Published private(set) var correctionStatus = "Ожидает проверки раскладки"
    @Published private(set) var inputMonitoringGranted = false

    private var hotKeyController: HotKeyController?
    private var wordMonitor: WordMonitor?

    init() {
#if DEBUG
        assert(LayoutCorrectionEngine.remapped("ghbdtn") == "привет")
        assert(LayoutCorrectionEngine.correction(for: "ghbdtn") == "привет")
        assert(LayoutCorrectionEngine.correction(for: "hello") == nil)
        assert(LayoutCorrectionEngine.correction(for: "привет") == nil)
#endif
        let monitor = WordMonitor { [weak self] word, delimiter in
            self?.finishWord(word, delimiter: delimiter)
        }
        wordMonitor = monitor

        inputMonitoringGranted = CGPreflightListenEventAccess()
        if inputMonitoringGranted {
            monitor.start()
        }

        let controller = HotKeyController { [weak self] in
            self?.handleActivation()
        }
        hotKeyController = controller
        registrationError = controller.register()
    }

    func requestInputMonitoring() {
        inputMonitoringGranted = CGRequestListenEventAccess()
        correctionStatus = inputMonitoringGranted
            ? "Input Monitoring разрешён"
            : "Включите Aza в Input Monitoring и перезапустите"
        if inputMonitoringGranted {
            wordMonitor?.start()
        }
    }

    func stop() {
        hotKeyController?.stop()
        wordMonitor?.stop()
    }

    private func handleActivation() {
        activationCount += 1

        guard AXIsProcessTrusted() else {
            insertionStatus = "Разрешите Aza управлять компьютером"
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }

        guard let element = TextInsertion.focusedElement() else {
            insertionStatus = "Активное поле ввода не найдено"
            return
        }

        guard !SecureFieldDetector.isSecure(element) else {
            insertionStatus = "В защищённые поля Aza не вставляет"
            return
        }

        let insertResult = TextInsertion.insert("Тест Aza", into: element)
        insertionStatus = insertResult == .success
            ? "«Тест Aza» вставлен"
            : "Поле не поддерживает прямую вставку (\(insertResult.rawValue))"
    }

    private func finishWord(_ word: String, delimiter: String) {
        guard let corrected = LayoutCorrectionEngine.correction(for: word) else { return }

        guard let element = TextInsertion.focusedElement(),
              SecureFieldDetector.isTextInput(element),
              !SecureFieldDetector.isSecure(element) else {
            correctionStatus = "Поле нельзя исправлять"
            return
        }

        // Give the app time to process the delimiter keystroke; replaceTypedText
        // verifies the text before the caret still matches, so a moved caret
        // aborts the replacement instead of corrupting the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            guard TextInsertion.replaceTypedText(
                in: element,
                expecting: word + delimiter,
                with: corrected + delimiter
            ) else {
                self.correctionStatus = "Не удалось заменить слово"
                return
            }
            self.correctionCount += 1
            self.correctionStatus = self.selectInputSource(language: "ru")
                ? "\(word) → \(corrected); раскладка: RU"
                : "Слово исправлено, русская раскладка не найдена"
        }
    }

    private func selectInputSource(language: String) -> Bool {
        guard let source = TISCopyInputSourceForLanguage(language as CFString)?.takeRetainedValue() else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }
}
