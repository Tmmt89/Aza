import AppKit
import Carbon.HIToolbox

/// Global keyDown monitor that accumulates the word being typed and reports it
/// once a delimiter is pressed. Owner must call stop() explicitly; there is no
/// deinit cleanup because NSEvent.removeMonitor requires the main thread.
///
/// Два режима (ChechenAutocorrect.isActiveTapEnabled, читается на старте):
/// - пассивный (по умолчанию): NSEvent-монитор, слово исправляется ПОСЛЕ
///   вставки разделителя (AX-замена / синтетика в GlobalHotKey);
/// - активный: CGEventTap задерживает разделитель, onWordDecision решает,
///   и слово перепечатывается ДО того, как разделитель дошёл до поля —
///   ноль гонок с быстрым набором и работа в «глухих» webview.
@MainActor
final class WordMonitor {
    private var monitor: Any?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var currentWord = ""
    private var isTechnicalToken = false
    private var lastBundleID: String?
    private let onWordFinished: (_ word: String, _ delimiter: String) -> Void
    /// Активный режим: вернуть исправление — разделитель проглатывается,
    /// монитор стирает слово и печатает исправление с разделителем;
    /// nil — событие проходит как есть.
    var onWordDecision: ((_ word: String, _ delimiter: String) -> String?)?
    /// Вызывается при разрыве контекста (переключение приложения):
    /// владелец сбрасывает состояние фразы.
    var onContextBreak: (() -> Void)?

    init(onWordFinished: @escaping (_ word: String, _ delimiter: String) -> Void) {
        self.onWordFinished = onWordFinished
    }

    var isRunning: Bool { monitor != nil || eventTap != nil }

    func start() {
        guard !isRunning else { return }
        if ChechenAutocorrect.isActiveTapEnabled, startActiveTap() { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            azaAssumeMainUnchecked {
                self?.handlePassive(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes)
            self.tapSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            // Без инвалидации mach-порт жил бы до конца процесса — утечка
            // на каждом цикле stop/start (LatchStopKeys делает так же).
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        resetContext()
    }

    // MARK: Пассивный режим

    private func handlePassive(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != TextInsertion.syntheticEventMarker else {
            return
        }
        for finished in accumulate(event) {
            onWordFinished(finished.word, finished.delimiter)
        }
    }

    // MARK: Активный режим (CGEventTap)

    private func startActiveTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
                let monitor = Unmanaged<WordMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // Источник тапа стоит на главном runloop — колбэк главный.
                return azaAssumeMainUnchecked {
                    monitor.handleTap(type: type, event: cgEvent)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            azaDebugLog("Aza: active event tap creation failed, falling back to passive")
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        azaDebugLog("Aza: active event tap started")
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Систему нельзя оставлять без клавиатуры: отключённый по таймауту
        // тап молча убивает ввод — включаем обратно и пропускаем событие.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != TextInsertion.syntheticEventMarker,
              let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        let finished = accumulate(nsEvent)
        // ponytail: одно завершённое слово на нажатие; редкий мульти-ввод
        // (IME) проходит без замены.
        guard finished.count == 1, let single = finished.first,
              let corrected = onWordDecision?(single.word, single.delimiter) else {
            return Unmanaged.passUnretained(event)
        }
        // Слепая синтетика запрещена: клик в другое место того же приложения
        // не сбрасывает currentWord, и backspace-ы стёрли бы чужой текст.
        // retypeWord сверяет фокус (pid/окно/диапазон) и текст перед кареткой
        // с набранным словом; сверка не прошла — событие проходит как есть,
        // разделитель НЕ глотается, поле остаётся нетронутым.
        guard let element = TextInsertion.focusedElement(),
              !SecureFieldDetector.isSecure(element),
              TextInsertion.retypeWord(typed: single.word, delimiter: "",
                                       corrected: corrected + single.delimiter,
                                       tail: "", verifying: element) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    // MARK: Общий накопитель слова

    private func accumulate(_ event: NSEvent) -> [(word: String, delimiter: String)] {
        guard event.type == .keyDown else {
            resetContext()
            return []
        }
        // Политика исключений: менеджеры паролей и пользовательский список
        // не исправляются; остальные приложения — да. Secure-поля
        // отсекаются на уровне элемента в момент замены.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let bundleID, !ExcludedApps.isCorrectionDenied(bundleID: bundleID) else {
            resetContext()
            lastBundleID = bundleID
            return []
        }
        // Смена приложения — разрыв слова и контекста фразы: буфер не должен
        // переезжать между окнами.
        if bundleID != lastBundleID {
            lastBundleID = bundleID
            resetContext()
        }

        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            resetContext()
            return []
        }
        if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
            kVK_Escape].contains(Int(event.keyCode)) {
            resetContext()
            return []
        }
        if event.keyCode == UInt16(kVK_Delete) {
            if !currentWord.isEmpty {
                currentWord.removeLast()
            }
            return []
        }

        guard let characters = event.characters, !characters.isEmpty else {
            resetContext()
            return []
        }
        return accumulateCharacters(characters, wordPunctuation: KeyboardLayoutMap.wordPunctuation())
    }

    private func resetContext() {
        currentWord = ""
        isTechnicalToken = false
        onContextBreak?()
    }

    /// URL, email и идентификатор защищаем целиком до следующего пробела:
    /// @ или / не должны завершать слово и запускать его исправление.
    /// ponytail: quoted email с пробелами требует отдельного учёта кавычек;
    /// здесь границей токена остаётся whitespace.
    func accumulateCharacters(_ characters: String,
                              wordPunctuation: Set<Character>) -> [(word: String, delimiter: String)] {
        var finished: [(word: String, delimiter: String)] = []
        for character in characters {
            if character.isWhitespace, isTechnicalToken {
                resetContext()
                continue
            }
            // {, } и ~ в некоторых раскладках дают Х, Ъ и Ё: тогда они
            // продолжают слово; технический токен всё равно отсеет @.
            if (!wordPunctuation.contains(character)
                && "@/\\_:=$#`+-%&*^|~{}".contains(character))
                || (character.isNumber && character != "1") {
                currentWord = ""
                isTechnicalToken = true
                onContextBreak?()
            }
            if isTechnicalToken { continue }
            // !/? могут продолжить email до будущего @; как точку и
            // запятую, держим их до пробела и снимаем в движке как суффикс.
            if character.isLetter || wordPunctuation.contains(character) || "!?".contains(character) {
                currentWord.append(character)
            } else {
                // Без единой буквы это не слово, а число или пунктуация:
                // «1» из «1994» иначе засорял бы контекст фразы (сама «1»
                // — словообразующая только как двойник палочки: «1алам»).
                if currentWord.contains(where: \.isLetter) {
                    finished.append((currentWord, String(character)))
                }
                currentWord = ""
            }
        }
        return finished
    }
}
