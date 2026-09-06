import AppKit
import XCTest

@MainActor
final class ClipboardPresentationTests: XCTestCase {
    func testPreviewClosesWithClipboardAndDoesNotCaptureSystemShortcuts() async throws {
        let prayer = PrayerStore(notifications: NotificationsStub())
        let dictation = DictationController(clipboardStore: { nil }, microphoneAuthorization: { .denied })
        let store = IslandStore(startup: ClipboardStartup(), dictation: dictation,
                                prayer: prayer, registerShortcuts: false)
        store.show(.clipboard)
        store.clipboardPreviewID = UUID()
        store.show(.home)
        XCTAssertNil(store.clipboardPreviewID, "A preview cannot outlive the clipboard")
        store.show(.clipboard)
        store.clipboardPreviewID = UUID()
        store.show(.dictation)
        XCTAssertNil(store.clipboardPreviewID, "Dictation must release clipboard content and focus")

        for key: UInt16 in [49, 53] {
            for flags: NSEvent.ModifierFlags in [[], .capsLock, .command, .control, .option, .shift] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: key))
                XCTAssertEqual(IslandPanel.isClipboardPreviewCloseKey(event),
                               flags.isEmpty || flags == .capsLock)
            }
        }
        await prayer.shutdownForCleanup()
    }

    func testPreferenceAndBottomGeometryOnDifferentDisplays() throws {
        let suite = "aza-clipboard-presentation-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ClipboardPresentation.load(from: defaults), .island)
        defaults.set(ClipboardPresentation.bottom.rawValue, forKey: ClipboardPresentation.storageKey)
        XCTAssertEqual(ClipboardPresentation.load(from: defaults), .bottom)
        defaults.set("unknown", forKey: ClipboardPresentation.storageKey)
        XCTAssertEqual(ClipboardPresentation.load(from: defaults), .island)

        for screen in [NSRect(x: 0, y: 0, width: 1728, height: 1117),
                       NSRect(x: -1920, y: 0, width: 1920, height: 1080),
                       NSRect(x: 0, y: 1117, width: 2560, height: 1440),
                       NSRect(x: 0, y: -600, width: 800, height: 600)] {
            let frame = ClipboardPresentation.bottomFrame(on: screen)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertEqual(frame.minY, screen.minY + 8)
            XCTAssertEqual(frame.midX, screen.midX)
            XCTAssertEqual(frame.width, screen.width - 16)
            XCTAssertGreaterThanOrEqual(frame.height - 84, 142, "Cards fit below the toolbar")
            if screen.height > 800 {
                XCTAssertEqual(frame.height / screen.height, 0.30, accuracy: 0.001)
            }
        }
        XCTAssertEqual(IslandMode.clipboard.size(hasNotch: true), NSSize(width: 988, height: 228))
    }

    func testSlideKeepsWindowAndClickGeometryFixed() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: -3000, y: 0, width: 800, height: 300)
        let panel = IslandPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
        defer { panel.close() }
        panel.revealFromBottom()
        XCTAssertEqual(panel.frame, frame)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(panel.contentView?.frame.origin, .zero)
        XCTAssertEqual(panel.frame, frame)
        XCTAssertFalse(panel.ignoresMouseEvents)
        panel.dismissToBottom()
        XCTAssertTrue(panel.ignoresMouseEvents, "Dismissed clipboard must not swallow clicks")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(panel.frame, frame)
        panel.revealFromBottom(animated: false)
        XCTAssertEqual(panel.contentView?.frame.origin, .zero)
        XCTAssertTrue(panel.isVisible)
    }
}
