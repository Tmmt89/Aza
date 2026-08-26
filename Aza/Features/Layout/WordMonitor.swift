import AppKit
import Carbon.HIToolbox

/// Global keyDown monitor that accumulates the word being typed and reports it
/// once a delimiter is pressed. Owner must call stop() explicitly; there is no
/// deinit cleanup because NSEvent.removeMonitor requires the main thread.
@MainActor
final class WordMonitor {
    private var monitor: Any?
    private var currentWord = ""
    private var lastBundleID: String?
    private let onWordFinished: (_ word: String, _ delimiter: String) -> Void
    /// Вызывается при разрыве контекста (переключение приложения):
    /// владелец сбрасывает состояние фразы.
    var onContextBreak: (() -> Void)?

    init(onWordFinished: @escaping (_ word: String, _ delimiter: String) -> Void) {
        self.onWordFinished = onWordFinished
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        currentWord = ""
    }

    private func handle(_ event: NSEvent) {
        guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != TextInsertion.syntheticEventMarker else {
            return
        }

        // Политика исключений (спецификация §6): терминалы, IDE и менеджеры
        // паролей не исправляются; остальные приложения — да. Secure-поля
        // отсекаются на уровне элемента в момент замены.
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let bundleID, !ExcludedApps.isCorrectionDenied(bundleID: bundleID) else {
            currentWord = ""
            lastBundleID = bundleID
            onContextBreak?()
            return
        }
        // Смена приложения — разрыв слова и контекста фразы: буфер не должен
        // переезжать между окнами.
        if bundleID != lastBundleID {
            lastBundleID = bundleID
            currentWord = ""
            onContextBreak?()
        }

        // ponytail: ⌘V, text selection and IME are not tracked — known prototype limitation.
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

        let wordPunctuation = KeyboardLayoutMap.wordPunctuation()
        for character in characters {
            if character.isLetter || wordPunctuation.contains(character) {
                currentWord.append(character)
            } else {
                if !currentWord.isEmpty {
                    onWordFinished(currentWord, String(character))
                }
                currentWord = ""
            }
        }
    }
}
