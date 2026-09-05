#!/bin/bash
# Локальная замена CI (GitHub Actions отключён — биллинг): те же проверки,
# что и .github/workflows/build.yml, плюс аудит палочки. Отличие от CI:
# сборка идёт со штатной подписью «Aza Development» — вариант без подписи
# локально запрещён (§8.9 HANDOVER: сброс TCC).
#
# Запуск перед push:  Tools/check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== 1. Конвейер словаря"
(cd "$ROOT/Tools/BuildChechenLexicon" && swift test)

echo "== 2. Приложение: сборка и тесты"
xcodebuild -project "$ROOT/Aza.xcodeproj" -scheme Aza \
  -configuration Debug -destination 'platform=macOS,arch=arm64' test

echo "== 3. Аудит палочки"
python3 "$ROOT/Tools/palochka_audit.py" "$ROOT"

echo "== 4. Синтаксис скриптов"
# Скрипты рождают данные приложения и релизы — битый синтаксис не должен
# ждать ручного запуска.
python3 -m py_compile "$ROOT"/Tools/*.py
for script in "$ROOT"/Tools/*.sh; do
    bash -n "$script"
done
python3 "$ROOT/Tools/test_tools.py"

echo "✔ Все проверки прошли — можно пушить"
