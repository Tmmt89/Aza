import XCTest
import AppKit

final class DictationAnimationTests: XCTestCase {
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
