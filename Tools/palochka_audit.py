"""Аудит палочки: где в проекте какие кодовые точки используются.

Канон проекта — U+04CF («ӏ», строчная). Заглавная U+04C0 («Ӏ») допустима
только в пояснениях о самой проблеме двух кодовых точек.

Часть 1 (ОБЯЗАТЕЛЬНАЯ, ненулевой выход при расхождении): три таблицы
подмен обязаны быть синхронны — Palochka.substitutions (конвейер),
LayoutCorrectionEngine.palochkaLookalikes (движок) и
ChechenLexicon.ukrainianITwins (нормализация ввода). Раньше аудит их не
сверял, и инвариант §6 HANDOVER держался только на глазах.

Часть 2 (информационная): опись кодовых точек по файлам, как раньше.

Запуск: python3 Tools/palochka_audit.py [корень]
"""
import re
import sys
from pathlib import Path

SKIP_DIRS = {".build", ".git", ".github", "DerivedData", ".superdesign", "outputs", "work"}
CODE_FILES = {".swift", ".md", ".json", ".py"}

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")


def declared_chars(path, name):
    """Символы Set<Character>-декларации: литералы и \\u{...}-эскейпы."""
    text = (root / path).read_text(encoding="utf-8")
    match = re.search(name + r"\s*:\s*Set<Character>\s*=\s*\[(.*?)\]",
                      text, re.DOTALL)
    if not match:
        sys.exit(f"АУДИТ ПРОВАЛЕН: не нашёл декларацию {name} в {path}")
    body = match.group(1)
    chars = set(re.findall(r'"(.)"', re.sub(r"\\u\{[0-9A-Fa-f]+\}", "", body)))
    chars |= {chr(int(cp, 16)) for cp in re.findall(r"\\u\{([0-9A-Fa-f]+)\}", body)}
    return chars


EXPECTED_SUBSTITUTIONS = {"1", "I", "l", "\u0456", "\u0406"}
TABLES = [
    ("Tools/BuildChechenLexicon/Sources/ChechenLexiconCore/Palochka.swift",
     "substitutions", EXPECTED_SUBSTITUTIONS),
    ("Aza/Features/Layout/LayoutCorrectionEngine.swift",
     "palochkaLookalikes", EXPECTED_SUBSTITUTIONS),
    ("Aza/Core/ChechenLexicon.swift",
     "ukrainianITwins", {"\u0456", "\u0406"}),
]
failed = False
for path, name, expected in TABLES:
    actual = declared_chars(path, name)
    if actual != expected:
        failed = True
        fmt = lambda s: ", ".join(f"U+{ord(c):04X}" for c in sorted(s))
        print(f"РАСХОЖДЕНИЕ {path}::{name}: есть {{{fmt(actual)}}}, "
              f"ожидалось {{{fmt(expected)}}}")
if failed:
    sys.exit("АУДИТ ПРОВАЛЕН: таблицы подмен палочки разъехались (§6 HANDOVER)")
print("Таблицы подмен синхронны:", ", ".join(n for _, n, _ in TABLES))
print()

for path in sorted(root.rglob("*")):
    if not path.is_file() or path.suffix not in CODE_FILES:
        continue
    if any(part in SKIP_DIRS for part in path.parts):
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    upper = text.count("\u04c0")
    lower = text.count("\u04cf")
    ukrainian_i = text.count("\u0456")
    if upper or lower or ukrainian_i:
        lines = [
            f"  строка {i}: U+04C0 x{line.count(chr(0x4c0))}, U+04CF x{line.count(chr(0x4cf))}, U+0456 x{line.count(chr(0x456))}"
            for i, line in enumerate(text.split("\n"), 1)
            if "\u04c0" in line or "\u0456" in line
        ]
        problems = []
        if upper:
            problems.append("ЕСТЬ ЗАГЛАВНЫЕ")
        if ukrainian_i:
            problems.append("ЕСТЬ УКР-І (подмена палочки!)")
        status = ", ".join(problems) if problems else "OK"
        print(f"{path}: U+04CF={lower}, U+04C0={upper}, U+0456={ukrainian_i} [{status}]")
        for line_info in lines[:6]:
            print(line_info)
