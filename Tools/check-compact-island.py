#!/usr/bin/env python3
"""Run the actual island sizing code and check native text fits: python3 Tools/check-compact-island.py."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
store = (root / "Aza/Features/Island/IslandStore.swift").read_text()
style = (root / "Aza/Features/Design/AzaStyle.swift").read_text()
prayers = (root / "Aza/Features/Island/PrayerSchedule.swift").read_text()
source = "import AppKit\nimport SwiftUI\n"
source += style[style.index("enum AzaStyle"):style.index("enum AzaMotion")]
source += store[store.index("enum IslandMode"):store.index("enum ClipboardKind")]
source += prayers[prayers.index("enum PrayerKind"):prayers.index("struct PrayerDay")]
source += r'''
for width: CGFloat in [160, 185, 210, 240] {
    let size = IslandMode.idle.size(hasNotch: true, notchWidth: width)
    assert((size.width - width) / 2 == 104, "Each wing must stay 104 pt on every Mac")
}
assert(IslandMode.idle.size(hasNotch: false).width == 208)
assert(IslandMode.dictation.size(hasNotch: true).width == 534)
assert(IslandMode.dictation.size(hasNotch: false).width == 404)
assert(IslandMode.home.size(hasNotch: true).width == 864)
assert(IslandMode.idle.shoulder == 12 && IslandMode.idle.bottomRadius == 14)
let contentWidth: CGFloat = 104 - IslandMode.idle.shoulder - 12 - 8
func textWidth(_ text: String, size: CGFloat) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)]).width
}
for title in PrayerKind.allCases.map(\.title) + ["Намаз", "Буфер"] {
    assert(14 + 6 + textWidth(title, size: 12) <= contentWidth, "Prayer title overlaps camera: \(title)")
}
for label in ["23ч 59м", "59 сек", "5 мин", "Сейчас"] {
    assert(textWidth(label, size: 12) <= contentWidth, "Countdown overlaps camera: \(label)")
}
assert(textWidth("Скопировано", size: 10) <= contentWidth)
assert(textWidth("Изображение", size: 9) <= contentWidth)
assert(textWidth("в 23:59", size: 9) <= contentWidth)
print("Compact island: geometry on 4 notch sizes, no-notch fallback, other modes and native text fit OK")
'''
with tempfile.TemporaryDirectory(prefix="aza-compact-check-") as temporary:
    path = Path(temporary) / "main.swift"
    path.write_text(source)
    subprocess.run(["swift", str(path)], check=True)
