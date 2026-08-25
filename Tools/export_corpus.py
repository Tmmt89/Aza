"""Одноразовый экспорт колонки из parquet-датасета в обычный текст.

Понадобился потому, что HuggingFace хранит корпусы в формате parquet,
а конвейер словаря читает простой текст UTF-8.

Зависимость: pip3 install --user pyarrow

Запуск:
    python3 Tools/export_corpus.py <файл.parquet> <выход.txt> [имя_колонки]

Пример:
    python3 Tools/export_corpus.py datasets/chechen-russian.parquet \
        datasets/corpus_che.txt che
"""
import sys

import pyarrow.parquet as pq

if len(sys.argv) < 3:
    print(__doc__)
    sys.exit(2)

parquet_path, out_path = sys.argv[1], sys.argv[2]
column = sys.argv[3] if len(sys.argv) > 3 else None

table = pq.read_table(parquet_path)
print("колонки:", table.column_names)

if column is None:
    column = table.column_names[0]
values = table.column(column).to_pylist()

lines = [value.strip() for value in values if value and value.strip()]
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")

print(f"записано {len(lines)} строк → {out_path}")
