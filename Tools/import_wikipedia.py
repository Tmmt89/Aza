"""Импорт Чеченской Википедии (wikimedia/wikipedia, конфиг 20231101.ce)
в текстовый корпус для конвейера словаря.

Фильтры против бот-стабов и нерелевантных статей:
- заголовок статьи обязан содержать кириллицу (отсекает латинские
  биологические виды и прочий автогенерированный спам);
- текст статьи не короче MIN_CHARS (стабы не несут лексики);
- ограничение MAX_ARTICLES, чтобы пересборка оставалась быстрой.

Зависимость: pip3 install --user pyarrow

Запуск: python3 Tools/import_wikipedia.py <part1.parquet> [part2.parquet …] <выход.txt>
"""
import sys
from pathlib import Path

import pyarrow.parquet as pq

MIN_CHARS = 800
MAX_ARTICLES = 12000


def has_cyrillic(text: str) -> bool:
    return any(0x0400 <= ord(ch) <= 0x04FF for ch in text)


if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

parquets = sys.argv[1:-1]
out_path = Path(sys.argv[-1])

articles = []
for parquet_path in parquets:
    table = pq.read_table(parquet_path)
    titles = table.column("title").to_pylist()
    texts = table.column("text").to_pylist()
    for title, text in zip(titles, texts):
        if len(articles) >= MAX_ARTICLES:
            break
        if not text or len(text) < MIN_CHARS:
            continue
        if not has_cyrillic(title):
            continue
        articles.append(f"{title}\n{text.strip()}")

out_path.write_text("\n\n".join(articles) + "\n", encoding="utf-8")
print(f"отобрано статей: {len(articles)}, записано в {out_path}")
