#!/bin/bash
# Ищет в трекаемых файлах данные из расписаний намаза, на распространение
# которых нет разрешения (docs/PLAN-prayer-schedules.md).
#
# Сравнивает со ВСЕМИ каталогами из папки, откуда их читает приложение.
# Четыре и более подряд идущих значения из одного дня — отказ (код 1).
# Три подряд — только предупреждение: времена намаза структурно похожи,
# и расчётный вывод случайно совпадает с фрагментами настоящих таблиц.
#
# ЧЕГО СКРИПТ НЕ ЛОВИТ (не выдавать его зелёный за доказательство):
#   * одиночное значение — в каталоге встречается 1401 из 1440 возможных
#     значений ЧЧ:ММ, поэтому такая проверка утонула бы в ложных
#     срабатываниях;
#   * скопированный день, у которого ПОДПРАВИЛИ значение в середине, —
#     непрерывных четвёрок после этого не остаётся.
# За тем и другим нужен ревьюер.
#
# Без установленных каталогов возвращает 2: зелёный CI без данных не
# должен выглядеть как пройденная проверка.
set -u
ROOT="$(git rev-parse --show-toplevel)" || {
    echo "ОШИБКА: не git-репозиторий"; exit 2
}
cd "$ROOT" || exit 2

DIR="${AZA_SCHEDULE_DIR:-$HOME/Library/Application Support/Aza/prayer-schedules}"

python3 - "$DIR" <<'PY'
import json, os, re, subprocess, sys

directory = sys.argv[1]
try:
    names = os.listdir(directory)
except OSError:
    names = []
# Регистронезависимо — приложение принимает файлы так же.
paths = sorted(os.path.join(directory, n) for n in names
               if n.lower().endswith(".json"))
if not paths:
    print("ПРОПУЩЕНО: каталоги расписаний не найдены в", directory,
          "— проверка не выполнена")
    sys.exit(2)

HARD, SOFT = 4, 3
hard_runs, soft_runs, days = set(), set(), 0
for path in paths:
    try:
        catalog = json.load(open(path, encoding="utf-8"))
    except (OSError, ValueError) as error:
        print("НЕ ПРОЧИТАН:", os.path.basename(path), error)
        sys.exit(2)
    for city in catalog.get("cities", []):
        for day in city.get("days", []):
            times = tuple(day.get("times", []))
            if not times:
                continue
            days += 1
            for i in range(len(times) - HARD + 1):
                hard_runs.add(times[i : i + HARD])
            for i in range(len(times) - SOFT + 1):
                soft_runs.add(times[i : i + SOFT])

listing = subprocess.run(["git", "ls-files"], capture_output=True, text=True)
if listing.returncode != 0:
    print("ОШИБКА: git ls-files вернул", listing.returncode, listing.stderr.strip())
    sys.exit(2)
tracked = listing.stdout.split()

hits, warnings = [], []
for name in tracked:
    try:
        text = open(name, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    found = re.findall(r"\b([0-2]\d:[0-5]\d)\b", text)
    # Без break: одно совпадение в файле не повод молчать об остальных.
    seen = set()
    for i in range(len(found) - HARD + 1):
        run = tuple(found[i : i + HARD])
        if run in hard_runs and run not in seen:
            seen.add(run)
            hits.append((name, " ".join(run)))
    for i in range(len(found) - SOFT + 1):
        run = tuple(found[i : i + SOFT])
        if run in soft_runs and run not in seen and not any(
            run == h[i : i + SOFT] for h in seen for i in range(HARD - SOFT + 1)
        ):
            seen.add(run)
            warnings.append((name, " ".join(run)))

for name, sample in hits:
    print("УТЕЧКА:", name, "|", sample)
for name, sample in warnings:
    print("посмотреть глазами:", name, "|", sample,
          "| три подряд — возможно совпадение, возможно копия")
print("проверено файлов:", len(tracked), "| каталогов:", len(paths),
      "| дней:", days)
sys.exit(1 if hits else 0)
PY
