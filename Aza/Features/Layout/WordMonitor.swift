import AppKit
import Carbon.HIToolbox

/// Global keyDown monitor that accumulates the word being typed and reports it
/// once a delimiter is pressed. Owner must call stop() explicitly; there is no
/// deinit cleanup because NSEvent.removeMonitor requires the main thread.
@MainActor
final class WordMonitor {
    private var monitor: Any?
    private var currentWord = ""
    private let onWordFinished: (_ word: String, _ delimiter: String) -> Void

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

        // ponytail: TextEdit-only proof; widen with the application exclusion policy after the system path is proven.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.TextEdit" else {
            currentWord = ""
            return
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

        // ponytail: , . map to б/ю but stay delimiters, and shifted keys ({ } : ")
        // break the word — words needing those won't correct; revisit in Stage 5.
        for character in characters {
            if character.isLetter || LayoutCorrectionEngine.wordPunctuation.contains(character) {
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
