"""Экспорт списка русских слов для фильтра конвейера словаря.

Чеченский корпус содержит русские заимствования («мало», «было»), которые
портят чеченский частотный словарь: движок коррекции путает их с целевыми
словами. Этот скрипт выгружает список русской лексики из pyspellchecker
(лицензия MIT), чтобы конвейер исключил её при сборке.

Список ограничен словами с русской частотой ≥ MIN_RU_FREQ: хвост
pyspellchecker содержит мусорные строки («ху» 118, «ду» 119, «вай» 58),
случайно совпадающие с базовыми чеченскими словами, — фильтр из них
вычёркивал чеченскую лексику. Настоящие русские слова на порядки чаще
(«мало» 2772, «было» 45895), порог 500 разделяет классы с запасом.

Зависимость: pip3 install pyspellchecker

Запуск: python3 Tools/export_russian_words.py <выход.txt> [min_freq=500]
"""
from spellchecker import SpellChecker
import sys
from pathlib import Path

if len(sys.argv) not in (2, 3):
    print(__doc__)
    sys.exit(2)

MIN_RU_FREQ = int(sys.argv[2]) if len(sys.argv) == 3 else 500

spell = SpellChecker(language="ru")
words = sorted(
    w for w, freq in spell.word_frequency.dictionary.items()
    if len(w) >= 2 and w.isalpha() and w.islower() and freq >= MIN_RU_FREQ
)

out = Path(sys.argv[1])
out.write_text("\n".join(words) + "\n", encoding="utf-8")
print(f"русских слов записано: {len(words)} → {out}")
