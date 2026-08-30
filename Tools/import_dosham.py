"""Импорт заголовочных слов из laamxo/dosham (unified.json) в простой текст.

Извлекает ТОЛЬКО чеченские заголовочные слова (поля word1/word1 — очищенная
форма). Русские переводы (поле translate) и HTML-разметку не берём вовсе:
они не должны попадать в частотный словарь чеченских слов.

Запуск: python3 Tools/import_dosham.py <unified.json> <выход.txt>
"""
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    print(__doc__)
    sys.exit(2)

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

# Берём ТОЛЬКО чистые чеченско-русские словари (заголовок — чеченское слово).
# Двунаправленные (_ce_ru_ru_ce) исключаем: в них половина заголовков русская,
# и отличить направление по записи невозможно.
seen = []
seen_set = set()
for entry in data:
    parent = entry.get("parent") or ""
    if "ce_ru" not in parent or "ru_ce" in parent:
        continue
    # word1 — нормализованное написание; word — только ЗАПАСНОЙ вариант.
    # Обработка обоих полей сразу тащила из повреждённых записей обломки
    # перевода («гнев.» → «гнев» в словаре с частотой 3).
    raw = entry.get("word1") or entry.get("word") or ""
    # Поле с табами/разметкой — повреждённая запись, не заголовок.
    if "\t" in raw or "<" in raw:
        continue
    for part in raw.split(","):
        word = part.strip().strip("-–")
        if not word or word in seen_set:
            continue
        # Заголовочное слово — ТОЛЬКО кириллица (плюс канонные подмены
        # палочки 1/I/l и дефис): точка, скобка, пробел, латиница внутри —
        # обломок перевода или OCR, а не слово.
        allowed_extra = set("1Il-")
        if not word or not all(
            0x0400 <= ord(ch) <= 0x04FF or ch in allowed_extra for ch in word
        ):
            continue
        if not any(0x0400 <= ord(ch) <= 0x04FF for ch in word):
            continue
        # Эвристика против русских слов из OCR: в чеченской орфографии
        # не встречаются ы/щ/э/ъ/ё и инфинитивы на -ть/-ся.
        lowered = word.lower()
        if any(ch in lowered for ch in "ыщэъё"):
            continue
        if lowered.endswith(("ть", "ся")):
            continue
        seen_set.add(word)
        seen.append(word)

Path(sys.argv[2]).write_text("\n".join(seen) + "\n", encoding="utf-8")
print(f"уникальных заголовочных слов: {len(seen)}")
