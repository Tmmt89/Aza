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

/// Замена MainActor.assumeIsolated для ВСЕХ синхронных колбэков главного
/// потока (tap'ы, таймеры, NSEvent-мониторы, нотификации). Штатный
/// assumeIsolated падал SIGSEGV (31.08, tap) и SIGBUS (04.09, таймер
/// PasteboardMonitor после контекстного меню): swift_task_isCurrentExecutor
/// читает TLS «текущий executor», который внутри/после вложенных
/// tracking-петель AppKit оказывается мусорным, и разыменовывает его.
/// Поток проверяем сами — все источники стоят на главном runloop.
func azaAssumeMainUnchecked<T>(_ body: @MainActor () -> T) -> T {
    precondition(Thread.isMainThread, "tap callback вне главного потока")
    return withoutActuallyEscaping(body) { escaping in
        unsafeBitCast(escaping, to: (() -> T).self)()
    }
}

/// Coordinator: wires the hot key, the word monitor and text insertion together
/// and exposes status for the menu panel. Lives for the whole app lifetime.
@MainActor
final class GlobalHotKey: ObservableObject {
    @Published private(set) var registrationError: OSStatus?
    // Диагностические поля без @Published: UI их не читает, а каждое
    // исправление дёргало бы SwiftUI-инвалидацию впустую.
    private(set) var activationCount = 0
    private(set) var insertionStatus = "Ожидает проверки вставки"
    private(set) var correctionCount = 0
    private(set) var correctionStatus = "Ожидает проверки раскладки"
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
        /// Окно и процесс, где исправляли: откат в другом окне (или, при
        /// недоступных окнах, в другом приложении) с совпавшим текстом
        /// перед кареткой переписал бы чужое поле. Точнее поле не привязать:
        /// CFEqual для AX-обёрток полей не работает (§TextInsertion.processID),
        /// остаточный риск закрывает обязательное совпадение текста замены.
        let window: AXUIElement?
        let pid: pid_t?
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
        monitor.onWordDecision = { [weak self] word, delimiter in
            self?.activeDecision(word: word, delimiter: delimiter)
        }
        wordMonitor = monitor

        inputMonitoringGranted = CGPreflightListenEventAccess()
        // Диагностика цепочки коррекции в unified log (без содержимого ввода):
        // log stream --predicate 'process == "Aza"'
        // ChechenLexicon здесь НЕ трогаем: обращение в интерполяции парсило
        // 1,4 МБ TSV синхронно в init (и в Release — аргумент вычисляется
        // до #if DEBUG внутри azaDebugLog). Прогрев — после старта UI.
        azaDebugLog("Aza: start inputMonitoring=\(inputMonitoringGranted ? 1 : 0) axTrusted=\(AXIsProcessTrusted() ? 1 : 0) layoutTable=\(LayoutCorrectionEngine.isAvailable ? 1 : 0)")
        DispatchQueue.main.async {
            azaDebugLog("Aza: lexicon=\(ChechenLexicon.shared.isAvailable ? 1 : 0)")
        }
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
        _ = CGRequestListenEventAccess()
        refreshInputMonitoring()
    }

    func refreshInputMonitoring() {
        inputMonitoringGranted = CGPreflightListenEventAccess()
        if inputMonitoringGranted {
            wordMonitor?.start()
            startUndoMonitor()
        } else {
            wordMonitor?.stop()
            if let shiftMonitor { NSEvent.removeMonitor(shiftMonitor) }
            shiftMonitor = nil
            recentWords.removeAll()
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
            azaAssumeMainUnchecked {
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
        guard now.timeIntervalSince(lastRightShiftPress) < 0.7 else {
            lastRightShiftPress = now
            return
        }
        // Сброс окна БЕЗ defer: defer перезаписывал .distantPast обратно
        // на now, и тройной тап срабатывал как два undo подряд.
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
        // Deny-list действует и на ручные пути: менеджер паролей нельзя
        // трогать даже по явному жесту пользователя (инвариант §6).
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           ExcludedApps.isCorrectionDenied(bundleID: bundleID) {
            correctionStatus = "В этом приложении Aza текст не трогает"
            return
        }
        guard let element = TextInsertion.focusedElement(),
              TextInsertion.isTextLike(element),
              !SecureFieldDetector.isSecure(element) else {
            correctionStatus = "Поле для отмены недоступно"
            return
        }
        // pid строго: нечитаемый pid с любой стороны — отказ, не nil == nil.
        guard Self.sameWindow(last.window, TextInsertion.window(of: element)),
              let lastPid = last.pid,
              lastPid == TextInsertion.processID(of: element) else {
            correctionStatus = "Отменять можно только в окне, где исправляли"
            return
        }

        var undone = TextInsertion.replaceTypedText(
            in: element,
            expecting: last.corrected + last.delimiter,
            with: last.original + last.delimiter
        )
        // Поле, где AX-замена не применяется (webview): откат той же
        // сверенной синтетикой, что и исправление.
        if !undone,
           let tail = TextInsertion.typedTail(after: last.corrected + last.delimiter,
                                              in: element, maxTail: 12) {
            undone = TextInsertion.retypeWord(typed: last.corrected,
                                              delimiter: last.delimiter,
                                              corrected: last.original, tail: tail,
                                              verifying: element)
        }
        if undone {
            // Каждое слово фразы отдельно: исключения работают пословно.
            for word in last.originalWords {
                UserWordLists.shared.addNeverCorrect(word)
            }
            // Пользователь передумал — подтверждение снимается.
            UserWordLists.shared.removeConfirmed(last.corrected)
            recentWords.removeAll()
            // Честный статус: сбой записи списка означает, что исключение
            // не переживёт перезапуск.
            correctionStatus = UserWordLists.shared.lastSaveFailed
                ? "Отменено: \(last.corrected) → \(last.original); исключение НЕ сохранилось на диск"
                : "Отменено: \(last.corrected) → \(last.original); в исключениях"
            lastCorrection = nil
        } else {
            // Текст изменился — контекст фразы больше не соответствует полю.
            recentWords.removeAll()
            correctionStatus = "Не удалось отменить (текст перед курсором изменился)"
        }
    }

    /// ⌘⇧A — принудительный ремап слова перед кареткой: выход для всех
    /// случаев, где автоматика воздержалась. Результат заносится в
    /// подтверждённые — дальше это слово исправляется само.
    private func handleActivation() {
        activationCount += 1

        guard AXIsProcessTrusted() else {
            insertionStatus = "Разрешите Aza управлять компьютером"
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            return
        }

        // Тот же deny-list, что у автоматики: ручной ⌘⇧A в менеджере
        // паролей раньше обходил исключения.
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           ExcludedApps.isCorrectionDenied(bundleID: bundleID) {
            insertionStatus = "В этом приложении Aza текст не трогает"
            return
        }

        guard let element = TextInsertion.focusedElement(),
              !SecureFieldDetector.isSecure(element) else {
            insertionStatus = "Поле для исправления недоступно"
            return
        }

        guard let token = TextInsertion.tokenBeforeCaret(in: element), !token.isEmpty else {
            insertionStatus = "Перед курсором нет слова"
            return
        }

        let isCyrillic = token.unicodeScalars.contains { (0x400...0x4FF).contains($0.value) }
        let target = isCyrillic ? "en" : "ru"
        guard let table = KeyboardLayoutMap.table(from: isCyrillic ? "ru" : "en", to: target),
              let mapped = LayoutCorrectionEngine.remapped(token, table: table) else {
            insertionStatus = "«\(token)» не ремапится в другую раскладку"
            return
        }

        var replaced = TextInsertion.replaceTypedText(in: element, expecting: token, with: mapped)
        if !replaced,
           let tail = TextInsertion.typedTail(after: token, in: element, maxTail: 2) {
            replaced = TextInsertion.retypeWord(typed: token, delimiter: "",
                                                corrected: mapped, tail: tail,
                                                verifying: element)
        }
        guard replaced else {
            insertionStatus = "Не удалось заменить «\(token)»"
            return
        }

        correctionCount += 1
        UserWordLists.shared.addConfirmed(mapped)
        lastCorrection = LastCorrection(original: token, corrected: mapped,
                                        delimiter: "", originalWords: [token],
                                        window: TextInsertion.window(of: element),
                                        pid: TextInsertion.processID(of: element))
        let switched = InputSourceSwitcher.select(language: target) == nil
        let status = "\(token) → \(mapped)" + (switched ? "; раскладка: \(target.uppercased())" : "")
        insertionStatus = status
        correctionStatus = status
        azaDebugLog("Aza: manual remap len=\(token.count) -> \(target)")
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

    /// Общая часть пассивного и активного путей: контекст фразы, движок,
    /// защита от системной автозамены и запоминание неисправленных слов.
    /// nil — исправлять нечего (вся сопутствующая работа уже сделана).
    private func evaluate(word: String, delimiter: String) -> (text: String, inputLanguage: String?)? {
        inputGeneration &+= 1
        // Без раскладки исправляем только опечатки, не копим контекст фразы.
        guard ChechenAutocorrect.isLayoutCorrectionEnabled else {
            recentWords.removeAll()
            return LayoutCorrectionEngine.correction(for: word)
        }
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
        guard correction != nil else {
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
                          ChechenAutocorrect.isLayoutCorrectionEnabled,
                          TextInsertion.focusSafeForPaste(
                            targetPid: TextInsertion.processID(of: element), verifying: element),
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
            return nil
        }
        return correction
    }

    private func finishWord(_ word: String, delimiter: String) {
        guard let correction = evaluate(word: word, delimiter: delimiter) else { return }

        // Бэквард-контекст: исправление оказалось чеченским (или русским)
        // словом — непрерывный хвост предыдущих НЕисправленных слов с
        // подходящим ремапом включается в ту же атомарную замену:
        // "[e le wbuf[m" → «[e ду цигахь», "e vtyz" → «у меня».
        let previous = recentWords.map {
            LayoutCorrectionEngine.PhraseWord(
                typed: $0.typed, delimiter: $0.delimiter,
                chechen: $0.chechen, corrected: $0.corrected)
        }
        var span = LayoutCorrectionEngine.backwardContextSpan(
            previous: previous, correctedWord: correction.text)
        if span == nil, correction.inputLanguage == "ru" {
            span = LayoutCorrectionEngine.backwardRussianSpan(
                previous: previous, correctedWord: correction.text)
        }
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
            // Electron, разбуженный этим же вызовом focusedElement: дерево
            // доступности строится асинхронно, и первое слово раньше
            // пропадало. Одна повторная попытка; сверки внутри
            // applyCorrection не дадут переписать чужой текст.
            let generation = inputGeneration
            let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                guard let self, self.inputGeneration == generation,
                      let targetPid,
                      TextInsertion.focusSafeForPaste(targetPid: targetPid),
                      let element = TextInsertion.focusedElement(),
                      !SecureFieldDetector.isSecure(element) else { return }
                azaDebugLog("Aza: retry after accessibility wake")
                self.applyCorrection(word: word, delimiter: delimiter,
                                     correction: correction,
                                     spanOriginal: spanOriginal,
                                     spanCorrected: spanCorrected,
                                     spanWords: spanWords, element: element)
            }
            return
        }

        // Give the app time to process the delimiter keystroke; replaceTypedText
        // verifies the text before the caret still matches, so a moved caret
        // aborts the replacement instead of corrupting the field.
        let generation = inputGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self, self.inputGeneration == generation else { return }
            self.applyCorrection(word: word, delimiter: delimiter,
                                  correction: correction,
                                  spanOriginal: spanOriginal,
                                  spanCorrected: spanCorrected,
                                  spanWords: spanWords, element: element)
        }
    }

    private func applyCorrection(word: String, delimiter: String,
                                 correction: (text: String, inputLanguage: String?),
                                 spanOriginal: String, spanCorrected: String,
                                 spanWords: [String], element: AXUIElement) {
            guard (ChechenAutocorrect.isLayoutCorrectionEnabled
                   || (spanOriginal.isEmpty
                       && LayoutCorrectionEngine.correction(for: word)?.text == correction.text)),
                  TextInsertion.focusSafeForPaste(
                    targetPid: TextInsertion.processID(of: element), verifying: element),
                  let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  !ExcludedApps.isCorrectionDenied(bundleID: bundleID) else { return }
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
                // AX-картинка поля ложная (webview: Claude-чат VS Code) —
                // текст правится только синтетическими клавишами. В обычном
                // поле, где слово читается, так делать нельзя: провал выше
                // означал сдвиг каретки, слепое стирание попало бы не туда.
                // Синтетика разрешена, когда стираемое сверено чтением по
                // диапазону (typedTail заодно возвращает буквы, напечатанные
                // за задержку, — они стираются и перепечатываются), ЛИБО
                // поле заведомо «врёт» через AX и сверить нечем (webview
                // с aria-подсказкой вместо содержимого).
                let tail = TextInsertion.typedTail(after: word + delimiter,
                                                   in: element, maxTail: 12)
                let fakeView = tail == nil
                    && TextInsertion.valueHidesTypedWord(in: element, typed: word)
                let retyped = (tail != nil || fakeView) && TextInsertion.retypeWord(
                    typed: word, delimiter: delimiter, corrected: correction.text,
                    tail: tail ?? "", verifying: element)
                azaDebugLog("Aza: synthetic retype verified=\(tail != nil ? 1 : 0) tail=\(tail?.count ?? -1) fake=\(fakeView ? 1 : 0) ok=\(retyped ? 1 : 0)")
                if retyped {
                    self.correctionCount += 1
                    self.recentWords.removeAll()
                    self.remember(FinishedWord(
                        typed: correction.text, delimiter: delimiter,
                        chechen: LayoutCorrectionEngine.looksChechen(correction.text),
                        corrected: true))
                    // Undo двойным Shift работает и здесь: откат идёт той же
                    // сверенной синтетикой.
                    self.lastCorrection = LastCorrection(
                        original: word, corrected: correction.text,
                        delimiter: delimiter, originalWords: [word],
                        window: TextInsertion.window(of: element),
                                        pid: TextInsertion.processID(of: element))
                    if let language = correction.inputLanguage,
                       InputSourceSwitcher.select(language: language) == nil {
                        self.correctionStatus =
                            "\(word) → \(correction.text); раскладка: \(language.uppercased())"
                    } else {
                        self.correctionStatus = "\(word) → \(correction.text)"
                    }
                    return
                }
                // Заменить не вышло — раскладку всё равно переключаем:
                // намерение распознано, дальше печать уже на нужном языке.
                if let language = correction.inputLanguage,
                   InputSourceSwitcher.select(language: language) == nil {
                    self.correctionStatus =
                        "Поле не даёт заменить слово; раскладка: \(language.uppercased())"
                } else {
                    self.correctionStatus = "Не удалось заменить слово"
                }
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
                originalWords: usedSpan ? spanWords + [word] : [word],
                window: TextInsertion.window(of: element),
                pid: TextInsertion.processID(of: element)
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

    /// Активный режим: решение прямо в tap-колбэке. Вернуть исправление —
    /// WordMonitor проглотит разделитель и перепечатает слово ДО его
    /// вставки; nil — событие проходит.
    /// ponytail: фразовый бэквард-контекст здесь не расширяется — активная
    /// замена всегда пословная; добавить, если режим приживётся.
    private func activeDecision(word: String, delimiter: String) -> String? {
        guard let correction = evaluate(word: word, delimiter: delimiter) else { return nil }
        // Secure-поле: пропустить событие без замены. Элемент не нашёлся —
        // тоже пропуск: без него не проверить secure, а слепая замена в
        // возможном поле пароля хуже пропущенного исправления. Цена —
        // первое слово в Electron до пробуждения AX-дерева (как в пассиве).
        guard let element = TextInsertion.focusedElement(),
              !SecureFieldDetector.isSecure(element) else {
            remember(FinishedWord(typed: word, delimiter: delimiter,
                                  chechen: false, corrected: false))
            return nil
        }
        correctionCount += 1
        recentWords.removeAll()
        remember(FinishedWord(typed: correction.text, delimiter: delimiter,
                              chechen: LayoutCorrectionEngine.looksChechen(correction.text),
                              corrected: true))
        lastCorrection = LastCorrection(original: word, corrected: correction.text,
                                        delimiter: delimiter, originalWords: [word],
                                        window: TextInsertion.window(of: element),
                                        pid: TextInsertion.processID(of: element))
        if let language = correction.inputLanguage,
           InputSourceSwitcher.select(language: language) == nil {
            correctionStatus = "\(word) → \(correction.text); раскладка: \(language.uppercased())"
        } else {
            correctionStatus = "\(word) → \(correction.text)"
        }
        azaDebugLog("Aza: active replace len=\(word.count)")
        return correction.text
    }
}
