"""Приведение литералов палочки к канону проекта (U+04CF, «ӏ»).

Файлы, где U+04C0 упомянут НАМЕРЕННО (объяснение двух кодовых точек),
в списке не участвуют: LayoutCorrectionEngine.swift, ChechenLexiconCore/
Palochka.swift, тесты конвейера, HANDOVER.md, palochka_audit.py.

Запуск: python3 Tools/palochka_canonicalize.py
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FILES = [
    "Aza/GlobalHotKey.swift",
    "Tools/BuildChechenLexicon/Sources/ChechenLexiconCore/Normalizer.swift",
    "docs/SPEC.md",
    "PRODUCT_SPEC.md",
    # docs/PLAN-chechen.md ИСКЛЮЧЁН: §3.2 намеренно показывает заглавную
    # U+04C0 в объяснении двух кодовых точек — слепая замена калечила
    # документацию, оставляя подпись «U+04C0» рядом со строчным глифом.
    "docs/RESEARCH-layout-autocorrect.md",
    "docs/RESEARCH-features.md",
]

for relative in FILES:
    path = ROOT / relative
    text = path.read_text(encoding="utf-8")
    count = text.count("\u04c0")
    if count == 0:
        print(f"{relative}: уже канонично")
        continue
    path.write_text(text.replace("\u04c0", "\u04cf"), encoding="utf-8")
    print(f"{relative}: заменено {count} × U+04C0 → U+04CF")
