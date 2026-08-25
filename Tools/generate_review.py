"""Генератор материалов для проверки носителем (docs/REVIEW-salgiri.md).

Собирает из готового словаря три списка для ручной проверки salgiri:
топ частотных слов, слова с палочкой, вероятные имена собственные.

Запуск из корня проекта: python3 Tools/generate_review.py
"""
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEXICON = ROOT / "Tools/BuildChechenLexicon/out_lexicon/lexicon.tsv"
OUTPUT = ROOT / "docs/REVIEW-salgiri.md"

random.seed(25)  # воспроизводимая выборка

entries = []
for line in LEXICON.read_text(encoding="utf-8").splitlines():
    parts = line.split("\t")
    if len(parts) >= 2:
        word, count = parts[0], int(parts[1])
        capital_only = len(parts) > 2 and parts[2] == "1"
        entries.append((word, count, capital_only))

entries.sort(key=lambda entry: -entry[1])
top = entries[:40]
with_palochka = [e for e in entries if "\u04cf" in e[0]]
random.shuffle(with_palochka)
proper_nouns = [e for e in entries if e[2]]
proper_nouns.sort(key=lambda entry: -entry[1])
proper_sample = proper_nouns[:20]

def table(rows):
    head = "| # | слово | частота |\n|---|---|---|\n"
    return head + "".join(
        f"| {i} | `{word}` | {count} |\n"
        for i, (word, count, _capital_only) in enumerate(rows, 1)
    )

doc = f"""# Проверка носителем: задание для salgiri

> Цель: подтвердить качество чеченского словаря до включения орфографической
> автокоррекции. Отметьте ошибки прямо в этом файле (колонка « verdict »)
> или списком номеров. Порог автоприменения — 98% точности.

## Часть 1. Топ-40 частотных слов — это точно чеченские слова?

{table(top)}

## Часть 2. Слова с палочкой (случайные 20 из {len(with_palochka)}) — написание верное?

{table(with_palochka[:20])}

## Часть 3. «Только с заглавной» — это действительно имена собственные?

Эти слова автокоррекцией не трогаются вообще. Ложные попадания сюда
(нарицательные слова) пометьте — их нужно вернуть в обычную проверку.

{table(proper_sample)}

## Что дальше

- Результаты разметки становятся тестовыми фикстурами
  (`Tests/Fixtures/real_world_examples.json`) по паттерну LayoutFix.
- После этой проверки включается следующий этап: опечаточная автокоррекция
  (жёсткие условия принятия, выключена по умолчанию).
"""

OUTPUT.write_text(doc, encoding="utf-8")
print(f"готово: {OUTPUT}")
print(f"слов всего: {len(entries)}, с палочкой: {len(with_palochka)}, имён: {len(proper_nouns)}")
