import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Combine

/// Отладочный лог в файл (только Debug): stderr при запуске через `open`
/// теряется, unified log эти строки не отдаёт — файл надёжен. Содержимое
/// ввода не пишется — только длины и флаги.
func azaDebugLog(_ message: String) {
#if DEBUG
    NSLog("%@", message)
    let line = "\(Date()) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/aza-debug.log")
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
#endif
}

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
    /// При фразовой замене original/corrected содержат весь охваченный
    /// диапазон, originalWords — слова для занесения в исключения.
    private struct LastCorrection {
        let original: String
        let corrected: String
        let delimiter: String
        let originalWords: [String]
    }
    private var lastCorrection: LastCorrection?
    private var lastRightShiftPress = Date.distantPast

    /// Контекст фразы: последние завершённые слова как они стоят в тексте.
    /// chechen — слово чеченское (само или после исправления);
    /// corrected — замена уже применялась (назад не расширяемся).
    private struct FinishedWord {
        let typed: String
        let delimiter: String
        let chechen: Bool
        let corrected: Bool
    }
    private var recentWords: [FinishedWord] = []
    private static let contextWindow = 4
    /// Фокусное окно последнего слова: смена окна (другой документ, диалог)
    /// рвёт контекст фразы — буфер не должен переезжать между окнами.
    private var lastFocusedWindow: AXUIElement?

    init() {
#if DEBUG
        // The layout tables come from the system, so these only hold when the
        // user actually has a Russian keyboard layout installed.
        assert(TextInsertion.matchingCase(of: "Ghbdtn ", applyingTo: "привет ") == "Привет ")
        assert(TextInsertion.matchingCase(of: "ghbdtn ", applyingTo: "привет ") == "привет ")
        // Политика исключений: терминалы/IDE/менеджеры паролей запрещены,
        // обычные приложения разрешены.
        assert(ExcludedApps.isCorrectionDenied(bundleID: "com.apple.Terminal"))
        assert(ExcludedApps.isCorrectionDenied(bundleID: "com.jetbrains.intellij"))
        assert(ExcludedApps.isCorrectionDenied(bundleID: "com.1password.1password"))
        assert(ExcludedApps.isCorrectionDenied(bundleID: "com.apple.Spotlight"))
        assert(!ExcludedApps.isCorrectionDenied(bundleID: "com.apple.TextEdit"))
        assert(!ExcludedApps.isCorrectionDenied(bundleID: "ru.keepcoder.Telegram"))
        assert(!ExcludedApps.isCorrectionDenied(bundleID: "com.apple.Safari"))
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
            // Точное чеченское слово побеждает соседей по первой клавише:
            // «ларам» и «барам» отличаются первой клавишей и раньше взаимно
            // блокировали друг друга (реальный баг владельца).
            assert(LayoutCorrectionEngine.correction(for: "kfhfv")?.text == "ларам")
            assert(LayoutCorrectionEngine.correction(for: ",fhfv")?.text == "барам")
            assert(LayoutCorrectionEngine.correction(for: "wbuf[m")?.text == "цигахь")
            // Контекст фразы: короткие слова в чеченском окружении.
            // «ду»/«со» спасены из русского фильтра порогом частоты корпуса;
            // «ху» в литературном корпусе отсутствует (разговорная форма) —
            // появится с разговорным источником, хардкодить нельзя.
            if ChechenLexicon.shared.isAvailable {
                assert(LayoutCorrectionEngine.chechenContextRemap(for: "le") == "ду")
                assert(LayoutCorrectionEngine.chechenContextRemap(for: "cj") == "со")
                assert(LayoutCorrectionEngine.chechenContextRemap(for: "in") == nil,
                       "валидное английское слово не трогаем")
                assert(LayoutCorrectionEngine.chechenContextRemap(for: "BMW") == nil,
                       "ВЕРХНИЙ регистр внутри — бренд, не трогаем")
            }
            // Unambiguous Russian words are still corrected.
            assert(LayoutCorrectionEngine.correction(for: ",skj")?.text == "было")
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
        monitor.onContextBreak = { [weak self] in
            self?.recentWords.removeAll()
        }
        wordMonitor = monitor

        inputMonitoringGranted = CGPreflightListenEventAccess()
        // Диагностика цепочки коррекции в unified log (без содержимого ввода):
        // log stream --predicate 'process == "Aza"'
        azaDebugLog("Aza: start inputMonitoring=\(inputMonitoringGranted ? 1 : 0) axTrusted=\(AXIsProcessTrusted() ? 1 : 0) lexicon=\(ChechenLexicon.shared.isAvailable ? 1 : 0) layoutTable=\(LayoutCorrectionEngine.isAvailable ? 1 : 0)")
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
        recentWords.removeAll()
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
            // Каждое слово фразы отдельно: исключения работают пословно.
            for word in last.originalWords {
                UserWordLists.shared.addNeverCorrect(word)
            }
            recentWords.removeAll()
            correctionStatus = "Отменено: \(last.corrected) → \(last.original); в исключениях"
            lastCorrection = nil
        } else {
            // Текст изменился — контекст фразы больше не соответствует полю.
            recentWords.removeAll()
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

    /// Добавляет слово в контекст фразы, ограничивая окно.
    private func remember(_ entry: FinishedWord) {
        recentWords.append(entry)
        if recentWords.count > Self.contextWindow {
            recentWords.removeFirst()
        }
    }

    private func finishWord(_ word: String, delimiter: String) {
        // Смена фокусного окна внутри приложения (другой документ, диалог
        // сохранения) — тоже разрыв фразы; смену приложений рвёт WordMonitor.
        let window = TextInsertion.focusedWindow()
        if let last = lastFocusedWindow {
            if window == nil || !CFEqual(last, window!) {
                recentWords.removeAll()
            }
        }
        lastFocusedWindow = window

        var correction = LayoutCorrectionEngine.correction(for: word)

        // Форвард-контекст: после чеченского слова короткое (2 буквы; от
        // трёх работает обычный путь) слово с частотным чеченским ремапом
        // тоже исправляется: "wbuf[m le" → «цигахь ду».
        if correction == nil,
           word.count == 2,
           recentWords.last?.chechen == true,
           let remap = LayoutCorrectionEngine.chechenContextRemap(for: word) {
            correction = (remap, "ru")
        }

        azaDebugLog("Aza: finishWord len=\(word.count) correction=\(correction == nil ? 0 : 1)")
        guard let correction else {
            remember(FinishedWord(typed: word, delimiter: delimiter,
                                  chechen: LayoutCorrectionEngine.looksChechen(word),
                                  corrected: false))
            return
        }

        // Бэквард-контекст: исправление оказалось чеченским словом — вся
        // фраза, скорее всего, чеченская. Непрерывный хвост предыдущих
        // НЕисправленных слов с частотным чеченским ремапом включается в ту
        // же атомарную замену: "[e le wbuf[m" → «ху ду цигахь» (пока «ху»
        // нет в корпусе — «[e ду цигахь»). Слово без такого ремапа (бренд,
        // английское, русское) обрывает расширение и остаётся как есть.
        var spanOriginal = "", spanCorrected = ""
        var spanWords: [String] = []
        if ChechenLexicon.shared.contains(correction.text) {
            for previous in recentWords.reversed() {
                guard !previous.corrected, !previous.chechen,
                      let remap = LayoutCorrectionEngine.chechenContextRemap(for: previous.typed) else { break }
                spanOriginal = previous.typed + previous.delimiter + spanOriginal
                spanCorrected = remap + previous.delimiter + spanCorrected
                spanWords.insert(previous.typed, at: 0)
            }
        }

        guard let element = TextInsertion.focusedElement(),
              !SecureFieldDetector.isSecure(element) else {
            // Ролевой фильтр (isTextInput) намеренно не применяется: Notes,
            // браузеры и Electron отдают роли вне AXTextField/AXTextArea.
            // «Текстовость» функционально проверяет replaceTypedText: без
            // читаемого selected range и точного совпадения текста замены
            // не будет; secure-поля отсечены здесь.
            azaDebugLog("Aza: focused element missing or secure")
            correctionStatus = "Поле нельзя исправлять"
            recentWords.removeAll()
            return
        }

        // Give the app time to process the delimiter keystroke; replaceTypedText
        // verifies the text before the caret still matches, so a moved caret
        // aborts the replacement instead of corrupting the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            var usedSpan = !spanOriginal.isEmpty
            var replaced = TextInsertion.replaceTypedText(
                in: element,
                expecting: spanOriginal + word + delimiter,
                with: spanCorrected + correction.text + delimiter
            )
            // Буфер знает не все разделители (двойной пробел, пунктуация
            // между словами) — фраза может не совпасть с текстом. Тогда
            // исправляем хотя бы текущее слово.
            if !replaced, usedSpan {
                usedSpan = false
                replaced = TextInsertion.replaceTypedText(
                    in: element,
                    expecting: word + delimiter,
                    with: correction.text + delimiter
                )
            }
            azaDebugLog("Aza: replaceTypedText ok=\(replaced ? 1 : 0) span=\(usedSpan ? spanWords.count : 0)")
            guard replaced else {
                self.correctionStatus = "Не удалось заменить слово"
                self.remember(FinishedWord(typed: word, delimiter: delimiter,
                                           chechen: false, corrected: false))
                return
            }
            self.correctionCount += 1
            self.recentWords.removeAll()
            self.remember(FinishedWord(typed: correction.text, delimiter: delimiter,
                                       chechen: LayoutCorrectionEngine.looksChechen(correction.text),
                                       corrected: true))
            self.lastCorrection = LastCorrection(
                original: usedSpan ? spanOriginal + word : word,
                corrected: usedSpan ? spanCorrected + correction.text : correction.text,
                delimiter: delimiter,
                originalWords: usedSpan ? spanWords + [word] : [word]
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
