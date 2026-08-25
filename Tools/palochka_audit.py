"""Аудит палочки: где в проекте какие кодовые точки используются.

Канон проекта — U+04CF («ӏ», строчная). Заглавная U+04C0 («Ӏ») допустима
только в пояснениях о самой проблеме двух кодовых точек.

Запуск: python3 Tools/palochka_audit.py [корень]
"""
import sys
from pathlib import Path

SKIP_DIRS = {".build", ".git", ".github", "DerivedData", ".superdesign", "outputs", "work"}
CODE_FILES = {".swift", ".md", ".json", ".py"}

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")

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
