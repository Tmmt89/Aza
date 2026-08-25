"""Инвентаризация нестандартных символов в текстовом файле корпуса.

Печатает все символы вне ASCII и базовой кириллицы А-я с частотами.
Запуск: python3 Tools/char_inventory.py <файл.txt>
"""
import collections
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
counts = collections.Counter(text)

print("Символы вне ASCII и базовой кириллицы А-я:")
for ch, count in counts.most_common():
    codepoint = ord(ch)
    if codepoint > 127 and not (0x410 <= codepoint <= 0x44F):
        print(f"  U+{codepoint:04X} {ch!r}: {count}")
