"""Экспорт списка русских слов для фильтра конвейера словаря.

Чеченский корпус содержит русские заимствования («мало», «было»), которые
портят чеченский частотный словарь: движок коррекции путает их с целевыми
словами. Этот скрипт выгружает список русской лексики из pyspellchecker
(лицензия MIT), чтобы конвейер исключил её при сборке.

Зависимость: pip3 install pyspellchecker

Запуск: python3 Tools/export_russian_words.py <выход.txt>
"""
from spellchecker import SpellChecker
import sys
from pathlib import Path

if len(sys.argv) != 2:
    print(__doc__)
    sys.exit(2)

spell = SpellChecker(language="ru")
words = sorted(
    w for w, freq in spell.word_frequency.dictionary.items()
    if len(w) >= 2 and w.isalpha() and w.islower()
)

out = Path(sys.argv[1])
out.write_text("\n".join(words) + "\n", encoding="utf-8")
print(f"русских слов записано: {len(words)} → {out}")
