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
    private var shiftMonitor: Any?
    /// Последнее применённое исправление — для отката двойным правым Shift.
    private struct LastCorrection {
        let original: String
        let corrected: String
        let delimiter: String
    }
    private var lastCorrection: LastCorrection?
    private var lastRightShiftPress = Date.distantPast

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
            // Palochka normalization is lexicon-gated: applied only when exactly
            // one hypothesis is a real Chechen word; without a bundled lexicon
            // it falls back to the greedy rule.
            let normalized = LayoutCorrectionEngine.normalizedPalochka("1алам")
            if ChechenLexicon.shared.isAvailable {
                assert(normalized == nil || ChechenLexicon.shared.contains(normalized!))
            } else {
                assert(normalized == "ӏалам")
            }
            // Auto-capitalized first word of a sentence
            assert(LayoutCorrectionEngine.correction(for: "Ghbdtn")?.text == "Привет")
            // б and ю live on the , and . keys; Shift gives Х Ъ Ж Э Б Ю
            // plus the reported incident: typing "vfkj" (slipped first key)
            // used to produce «мало», although the neighbouring key '[' gives
            // Chechen «хало» from the lexicon — such input is now abstained.
            assert(LayoutCorrectionEngine.correction(for: "vfkj") == nil)
            // Unambiguous Russian words are still corrected.
            assert(LayoutCorrectionEngine.correction(for: ",skj")?.text == "было")
            assert(LayoutCorrectionEngine.correction(for: "k.,jdm")?.text == "любовь")
            assert(LayoutCorrectionEngine.correction(for: "{jhjij")?.text == "Хорошо")
            assert(LayoutCorrectionEngine.correction(for: "k.,jdm")?.text == "любовь")
            assert(LayoutCorrectionEngine.correction(for: "{jhjij")?.text == "Хорошо")
            // Trailing punctuation is punctuation, not a letter
            assert(LayoutCorrectionEngine.correction(for: "ghbdtn,")?.text == "привет,")
            assert(LayoutCorrectionEngine.correction(for: "hello,") == nil)
            assert(LayoutCorrectionEngine.correction(for: "привет,") == nil)
            // Typo stage is OFF by default (PLAN-chechen §3.3): while the
            // setting is untouched, a misspelled word must never be repaired.
            if !ChechenAutocorrect.isTypoCorrectionEnabled {
                assert(LayoutCorrectionEngine.correction(for: "баркла") == nil)
                assert(LayoutCorrectionEngine.correction(for: "превет") == nil)
            }
            // Clipboard pipeline self-test (Debug only): AES-GCM roundtrip,
            // no plaintext on disk, tampered file ignored.
            ClipboardStore.runSelfTest(sample: "буфер-самотест-\(UUID().uuidString)")
        }
#endif
        let monitor = WordMonitor { [weak self] word, delimiter in
            self?.finishWord(word, delimiter: delimiter)
        }
        wordMonitor = monitor

        inputMonitoringGranted = CGPreflightListenEventAccess()
        // Диагностика цепочки коррекции в unified log (без содержимого ввода):
        // log stream --predicate 'process == "Aza"'
        NSLog("Aza: start inputMonitoring=%d axTrusted=%d lexicon=%d layoutTable=%d",
              inputMonitoringGranted ? 1 : 0,
              AXIsProcessTrusted() ? 1 : 0,
              ChechenLexicon.shared.isAvailable ? 1 : 0,
              LayoutCorrectionEngine.isAvailable ? 1 : 0)
        if inputMonitoringGranted {
            monitor.start()
            startUndoMonitor()
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
            startUndoMonitor()
        }
    }

    func stop() {
        hotKeyController?.stop()
        wordMonitor?.stop()
        if let shiftMonitor {
            NSEvent.removeMonitor(shiftMonitor)
            self.shiftMonitor = nil
        }
    }

    // MARK: Отмена последнего исправления (двойной правый Shift)

    private func startUndoMonitor() {
        guard shiftMonitor == nil else { return }
        shiftMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleFlagsChanged(event)
            }
        }
    }

    /// flagsChanged приходит и на нажатие, и на отпускание; нажатием считаем
    /// момент, когда .shift ещё зажат, а код — именно правого Shift (54).
    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_RightShift),
              event.modifierFlags.contains(.shift) else { return }

        let now = Date()
        defer { lastRightShiftPress = now }
        guard now.timeIntervalSince(lastRightShiftPress) < 0.7 else { return }
        lastRightShiftPress = .distantPast
        undoLastCorrection()
    }

    /// Возвращает последнее исправление тем же проверенным механизмом замены
    /// (текст перед кареткой обязан совпасть) и заносит исходное слово в
    /// исключения — второй раз оно не исправляется.
    private func undoLastCorrection() {
        guard let last = lastCorrection else {
            correctionStatus = "Отменять нечего"
            return
        }
        guard let element = TextInsertion.focusedElement(),
              SecureFieldDetector.isTextInput(element),
              !SecureFieldDetector.isSecure(element) else {
            correctionStatus = "Поле для отмены недоступно"
            return
        }

        if TextInsertion.replaceTypedText(
            in: element,
            expecting: last.corrected + last.delimiter,
            with: last.original + last.delimiter
        ) {
            UserWordLists.shared.addNeverCorrect(last.original)
            correctionStatus = "Отменено: \(last.corrected) → \(last.original); в исключениях"
            lastCorrection = nil
        } else {
            correctionStatus = "Не удалось отменить (текст перед курсором изменился)"
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
        let correction = LayoutCorrectionEngine.correction(for: word)
        NSLog("Aza: finishWord len=%d correction=%d",
              word.count, correction == nil ? 0 : 1)
        guard let correction else { return }

        guard let element = TextInsertion.focusedElement(),
              SecureFieldDetector.isTextInput(element),
              !SecureFieldDetector.isSecure(element) else {
            NSLog("Aza: focused element missing, non-text or secure")
            correctionStatus = "Поле нельзя исправлять"
            return
        }

        // Give the app time to process the delimiter keystroke; replaceTypedText
        // verifies the text before the caret still matches, so a moved caret
        // aborts the replacement instead of corrupting the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            let replaced = TextInsertion.replaceTypedText(
                in: element,
                expecting: word + delimiter,
                with: correction.text + delimiter
            )
            NSLog("Aza: replaceTypedText ok=%d", replaced ? 1 : 0)
            guard replaced else {
                self.correctionStatus = "Не удалось заменить слово"
                return
            }
            self.correctionCount += 1
            self.lastCorrection = LastCorrection(
                original: word,
                corrected: correction.text,
                delimiter: delimiter
            )
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
