#!/bin/bash
# Собирает подписанный DMG и, если попросить, отправляет его на
# нотаризацию Apple.
#
# Скрипт НИЧЕГО не подписывает вслепую: без сертификата Developer ID он
# останавливается и объясняет, чего не хватает. Неподписанная сборка,
# выданная за готовую, хуже отсутствия сборки — на чужом Mac она просто
# не запустится.
#
# Что нужно от владельца (один раз):
#   1. Учётная запись Apple Developer Program.
#   2. Сертификат «Developer ID Application» в связке ключей.
#   3. Пароль приложения (appleid.apple.com → Безопасность) ИЛИ ключ
#      App Store Connect API — для нотаризации.
#
# Запуск:
#   Tools/release.sh                      — собрать и подписать
#   Tools/release.sh --notarize           — плюс отправить на нотаризацию
#
# Переменные окружения (можно задать вместо автоопределения):
#   AZA_SIGN_IDENTITY   строка сертификата, например
#                       "Developer ID Application: Имя (TEAMID)"
#   AZA_TEAM_ID         идентификатор команды
#   AZA_KEYCHAIN_PROFILE  профиль notarytool (см. ниже)
#
# Профиль для нотаризации создаётся один раз:
#   xcrun notarytool store-credentials aza-notary \
#     --apple-id ПОЧТА --team-id TEAMID --password ПАРОЛЬ-ПРИЛОЖЕНИЯ
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build_release"
APP="$BUILD/Build/Products/Release/Aza.app"
DMG_DIR="$ROOT/dist"
NOTARIZE=0
[ "${1:-}" = "--notarize" ] && NOTARIZE=1

cd "$ROOT"

echo "== 1. Сертификат"
IDENTITY="${AZA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed 's/.*"\(.*\)"/\1/') || true
fi
if [ -z "$IDENTITY" ]; then
    cat <<'MISSING'
ОСТАНОВЛЕНО: не найден сертификат «Developer ID Application».

Без него сборку нельзя ни подписать, ни нотаризовать, а на чужом Mac
macOS её не запустит. Что сделать:

  1. Вступить в Apple Developer Program (99 $ в год).
  2. В Xcode: Settings → Accounts → Manage Certificates → «+» →
     Developer ID Application.
  3. Повторить запуск.

Собрать неподписанную версию для себя можно и так:
  xcodebuild -project Aza.xcodeproj -scheme Aza -configuration Release build
MISSING
    exit 2
fi
echo "   $IDENTITY"

TEAM="${AZA_TEAM_ID:-$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')}"
[ -n "$TEAM" ] || { echo "ОШИБКА: не определил team id, задайте AZA_TEAM_ID"; exit 2; }
echo "   команда: $TEAM"

echo "== 2. Сборка"
rm -rf "$BUILD"
xcodebuild -project Aza.xcodeproj -scheme Aza -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build > "$BUILD.log" 2>&1 || { tail -30 "$BUILD.log"; exit 1; }
[ -d "$APP" ] || { echo "ОШИБКА: приложение не собралось"; exit 1; }

echo "== 3. Проверка подписи"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/   /'
FLAGS=$(codesign -dv "$APP" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')
case "$FLAGS" in
    *runtime*) echo "   hardened runtime включён" ;;
    *) echo "ОШИБКА: hardened runtime выключен — нотаризация откажет"; exit 1 ;;
esac
if codesign -d --entitlements - "$APP" 2>&1 | grep -q "get-task-allow"; then
    echo "ОШИБКА: в сборке осталось get-task-allow — это отладочное право,"
    echo "        с ним нотаризация откажет"
    exit 1
fi

echo "== 4. DMG"
mkdir -p "$DMG_DIR"
VERSION=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "0")
DMG="$DMG_DIR/Aza-$VERSION.dmg"
rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Aza" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "   $DMG"

if [ "$NOTARIZE" -eq 0 ]; then
    echo
    echo "ГОТОВО (без нотаризации). Отправить: Tools/release.sh --notarize"
    exit 0
fi

echo "== 5. Нотаризация"
PROFILE="${AZA_KEYCHAIN_PROFILE:-aza-notary}"
if ! xcrun notarytool history --keychain-profile "$PROFILE" > /dev/null 2>&1; then
    cat <<MISSING
ОСТАНОВЛЕНО: профиль нотаризации «$PROFILE» не настроен.

Создайте его один раз:
  xcrun notarytool store-credentials $PROFILE \\
    --apple-id ВАША-ПОЧТА --team-id $TEAM --password ПАРОЛЬ-ПРИЛОЖЕНИЯ

Пароль приложения делается на appleid.apple.com → Безопасность →
Пароли приложений. Обычный пароль от Apple ID не подойдёт.

DMG уже собран и подписан: $DMG
MISSING
    exit 2
fi
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "   печать приклеена"

echo
echo "ГОТОВО: $DMG"
echo "Проверить так, как это сделает чужой Mac:"
echo "  spctl -a -t open --context context:primary-signature -v \"$DMG\""
