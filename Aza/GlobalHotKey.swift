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
        // The layout tables come from the system, so these only hold when the
        // user actually has a Russian keyboard layout installed.
        assert(TextInsertion.matchingCase(of: "Ghbdtn ", applyingTo: "привет ") == "Привет ")
        assert(TextInsertion.matchingCase(of: "ghbdtn ", applyingTo: "привет ") == "привет ")
        if LayoutCorrectionEngine.isAvailable {
            assert(LayoutCorrectionEngine.correction(for: "ghbdtn")?.text == "привет")
            assert(LayoutCorrectionEngine.correction(for: "руддщ")?.text == "hello")
            assert(LayoutCorrectionEngine.correction(for: "hello") == nil)
            assert(LayoutCorrectionEngine.correction(for: "привет") == nil)
            // Chechen words stay Cyrillic; EN-typed Chechen becomes Cyrillic
            assert(LayoutCorrectionEngine.correction(for: "хьо") == nil)
            assert(LayoutCorrectionEngine.correction(for: "къонах") == nil)
            assert(LayoutCorrectionEngine.correction(for: "[mj")?.text == "хьо")
            assert(LayoutCorrectionEngine.correction(for: "1алам")?.text == "ӏалам")
            // Auto-capitalized first word of a sentence
            assert(LayoutCorrectionEngine.correction(for: "Ghbdtn")?.text == "Привет")
            // б and ю live on the , and . keys; Shift gives Х Ъ Ж Э Б Ю
            assert(LayoutCorrectionEngine.correction(for: ",skj")?.text == "было")
            assert(LayoutCorrectionEngine.correction(for: "k.,jdm")?.text == "любовь")
            assert(LayoutCorrectionEngine.correction(for: "{jhjij")?.text == "Хорошо")
            // Trailing punctuation is punctuation, not a letter
            assert(LayoutCorrectionEngine.correction(for: "ghbdtn,")?.text == "привет,")
            assert(LayoutCorrectionEngine.correction(for: "hello,") == nil)
            assert(LayoutCorrectionEngine.correction(for: "привет,") == nil)
        }
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
        guard let correction = LayoutCorrectionEngine.correction(for: word) else { return }

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
                with: correction.text + delimiter
            ) else {
                self.correctionStatus = "Не удалось заменить слово"
                return
            }
            self.correctionCount += 1
            guard let language = correction.inputLanguage else {
                self.correctionStatus = "\(word) → \(correction.text)"
                return
            }
            if let failure = InputSourceSwitcher.select(language: language) {
                self.correctionStatus = "\(word) → \(correction.text); \(failure)"
            } else {
                self.correctionStatus = "\(word) → \(correction.text); раскладка: \(language.uppercased())"
            }
        }
    }
}
