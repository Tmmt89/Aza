import XCTest
import AppKit
import SwiftUI

final class DictationAnimationTests: XCTestCase {
    @MainActor
    func testNotchDismissalWaitsForAnimationAndCanBeReversed() async throws {
        _ = NSApplication.shared
        let frame = NSRect(x: -3000, y: 0, width: 400, height: 40)
        let panel = IslandPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RevealTestView(reveal: panel.reveal))
        host.sizingOptions = []
        panel.contentView = host
        defer { panel.close() }

        panel.revealAtNotch()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.reveal.isRevealed)
        XCTAssertEqual(panel.frame, frame, "Animation must preserve the click geometry")

        var completed = false
        panel.dismissAtNotch {
            XCTAssertFalse(panel.isVisible, "Show the next panel only after the old one is hidden")
            completed = true
        }
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.reveal.isRevealed)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertTrue(panel.isVisible, "Keep the outgoing panel alive while it contracts")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(panel.isVisible, "Do not remove the panel at the start of the animation")
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(completed)
        XCTAssertEqual(panel.frame, frame)

        panel.revealAtNotch(animated: false)
        try await Task.sleep(for: .milliseconds(80))
        panel.dismissAtNotch()
        try await Task.sleep(for: .milliseconds(60))
        panel.revealAtNotch()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(panel.isVisible, "An old dismissal must not hide a reopened panel")
        XCTAssertTrue(panel.reveal.isRevealed)
        XCTAssertFalse(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.frame, frame)

        // Close before the queued opening has even run.
        panel.dismissAtNotch(animated: false)
        panel.revealAtNotch()
        panel.dismissAtNotch(animated: false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.reveal.isRevealed)
    }

    func testDictationFitsEveryNotchWithoutAnimationJumps() {
        let labelWidth = ("Распознаю…" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width
        for notchWidth: CGFloat in [0, 160, 185, 210, 240] {
            let size = IslandMode.dictation.size(hasNotch: notchWidth > 0, notchWidth: notchWidth)
            let notchSpace = notchWidth > 0 ? notchWidth + 28 : 0
            let leftWidth = size.width - IslandMode.dictation.shoulder * 2 - 32 - notchSpace - 124
            XCTAssertGreaterThanOrEqual(leftWidth, 16 + 10 + labelWidth,
                                       "Status and spinner must fit beside the camera")
        }
        for index in 0..<7 {
            XCTAssertEqual(AzaMotion.dictationBarHeight(index: index, time: -1), 4)
            XCTAssertEqual(AzaMotion.dictationBarHeight(index: index, time: 0), 4)
            var previous = AzaMotion.dictationBarHeight(index: index, time: 0)
            for frame in 1...1800 {
                let height = AzaMotion.dictationBarHeight(index: index, time: Double(frame) / 60)
                XCTAssertTrue((4...26).contains(height), "Wave must fit the 26 pt recording area")
                XCTAssertLessThan(abs(height - previous), 2, "No jumps between frames")
                previous = height
            }
            XCTAssertNotEqual(AzaMotion.dictationBarHeight(index: index, time: 1),
                              AzaMotion.dictationBarHeight(index: index, time: 1.5))
        }
    }
}

private struct RevealTestView: View {
    @ObservedObject var reveal: IslandReveal

    var body: some View {
        Color.black
            .frame(width: reveal.isRevealed ? 400 : 64, height: 40)
            .frame(maxWidth: .infinity)
    }
}
