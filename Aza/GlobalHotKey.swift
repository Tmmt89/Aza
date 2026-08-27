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

    /// Поколение ввода: каждое завершённое слово его увеличивает, отменяя
    /// отложенные восстановления после системной автозамены — иначе restore
    /// для «лар» мог бы переписать следующее слово.
    private var inputGeneration = 0

    init() {
        let monitor = WordMonitor { [weak self] word, delimiter in
            self?.finishWord(word, delimiter: delimiter)
        }
        monitor.onContextBreak = { [weak self] in
            self?.recentWords.removeAll()
            self?.inputGeneration &+= 1
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
              TextInsertion.isTextLike(element),
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

    private static func sameWindow(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return CFEqual(x, y)
        default: return false
        }
    }

    /// Добавляет слово в контекст фразы, ограничивая окно.
    private func remember(_ entry: FinishedWord) {
        recentWords.append(entry)
        if recentWords.count > Self.contextWindow {
            recentWords.removeFirst()
        }
    }

    private func finishWord(_ word: String, delimiter: String) {
        inputGeneration &+= 1
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
           let remap = LayoutCorrectionEngine.forwardContextRemap(
            for: word, previousIsChechen: recentWords.last?.chechen == true
           ) {
            correction = (remap, "ru")
        }

        azaDebugLog("Aza: finishWord len=\(word.count) correction=\(correction == nil ? 0 : 1)")
        guard let correction else {
            let isChechen = LayoutCorrectionEngine.looksChechen(word)
            // Защита от системной автозамены macOS: она не знает чеченского
            // и «чинит» словарные слова в русские соседи («лар» → «лор»).
            // Через 30 мс сверяем поле с тем, что напечатано, и возвращаем
            // ввод пользователя. Только для слов из словаря — чужой ввод
            // и опечатки не трогаем.
            if ChechenLexicon.shared.contains(word),
               !UserWordLists.shared.isNeverCorrect(word),
               let element = TextInsertion.focusedElement(),
               !SecureFieldDetector.isSecure(element),
               let caretAtSchedule = TextInsertion.caretPosition(of: element) {
                let generation = inputGeneration
                let windowAtSchedule = TextInsertion.focusedWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
                    guard let self,
                          // Новое слово или разрыв контекста отменяет restore;
                          // элемент и каретка обязаны совпасть с моментом
                          // планирования — чужой текст не переписывается.
                          self.inputGeneration == generation,
                          // Компромисс: автозамена, менявшая длину слова,
                          // сдвигает каретку — restore тогда пропускается
                          // (лучше пропуск, чем риск чужого текста).
                          TextInsertion.caretPosition(of: element) == caretAtSchedule,
                          // Фокусное окно не сменилось: переключение окна
                          // без набора текста тоже отменяет restore.
                          Self.sameWindow(windowAtSchedule, TextInsertion.focusedWindow())
                    else { return }
                    if TextInsertion.restoreTypedWord(in: element, typed: word,
                                                      delimiter: delimiter) {
                        azaDebugLog("Aza: restored autocorrected word len=\(word.count)")
                        self.correctionStatus = "Отменена системная автозамена: \(word)"
                    }
                }
            }
            remember(FinishedWord(typed: word, delimiter: delimiter,
                                  chechen: isChechen, corrected: false))
            return
        }

        // Бэквард-контекст: исправление оказалось чеченским словом — вся
        // фраза, скорее всего, чеченская. Непрерывный хвост предыдущих
        // НЕисправленных слов с частотным чеченским ремапом включается в ту
        // же атомарную замену: "[e le wbuf[m" → «ху ду цигахь» (пока «ху»
        // нет в корпусе — «[e ду цигахь»). Слово без такого ремапа (бренд,
        // английское, русское) обрывает расширение и остаётся как есть.
        let span = LayoutCorrectionEngine.backwardContextSpan(
            previous: recentWords.map {
                .init(typed: $0.typed, delimiter: $0.delimiter,
                      chechen: $0.chechen, corrected: $0.corrected)
            },
            correctedWord: correction.text
        )
        let spanOriginal = span?.original ?? ""
        let spanCorrected = span?.corrected ?? ""
        let spanWords = span?.originalWords ?? []

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
