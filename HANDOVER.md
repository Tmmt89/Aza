# HANDOVER — Aza: полная передача контекста

> Обновлено: 25.08.2026. Заменяет предыдущую версию целиком.
> Для ИИ-агента или человека, подхватывающего работу. Все факты проверены
> по репозиторию; история — `git --no-pager log --oneline`.
>
> **Правило владельца:** после каждого шага — ревью и перепроверка себя;
> владелец общается на русском, комментарии в коде допустимы на английском.

## 1. Проект

Aza («голос» по-чеченски) — нативное macOS-приложение вокруг выреза MacBook:
время намаза, локальная диктовка, автокоррекция раскладки (ru/en/ce),
история буфера обмена. Некоммерческое, MIT, распространение через
подписанный DMG с сайта (НЕ App Store). Полная спецификация: `docs/SPEC.md`.

Фундаментальные принципы (не нарушать):
- всё локально: никакой телеметрии, аккаунтов, облачной синхронизации;
- никогда не трогать secure-поля, менеджеры паролей, терминалы, URL/email;
- ложное исправление хуже пропуска (асимметрия цены ошибки);
- сторонние зависимости — только после проверки лицензии (см. §6).

## 2. Карта репозитория

```
Aza/                     # Xcode-приложение (системный прототип)
  AzaApp.swift           # @main, MenuBarExtra (.window), старт мониторов
  ContentView.swift      # панель меню: статус, чеченские тумблеры, история буфера
  GlobalHotKey.swift     # фасад: хоткей ⌘⇧A, self-check ассерты при старте,
                         # finishWord → движок, undo двойным правым Shift
  Core/
    ChechenLexicon.swift     # ленивая загрузка lexicon.tsv, частоты,
                             # oneEditNeighbor / hasOneEditMatch / isFrequent
    ChechenAutocorrect.swift # настройки (UserDefaults), см. §5 «Настройки»
    UserWordLists.swift      # never-correct + подтверждённые слова,
                             # JSON в Application Support/Aza/user-words.json
    TextInsertion.swift      # AX-вставка, replaceTypedText, synthetic marker
    SecureFieldDetector.swift / InputSourceSwitcher.swift /
    KeyboardLayoutMap.swift  # таблицы раскладок берутся из системы
  Features/
    HotKeys/HotKeyController.swift
    Layout/LayoutCorrectionEngine.swift + WordMonitor.swift
  Resources/
    chechen-lexicon.tsv  # артефакт конвейера (30 845 слов, в git)
    README.md            # происхождение и лицензии источников
Sources/Aza/             # SPM-прототип UI острова (IslandStore/IslandView,
                         # PrayerSchedule) + Resources/prayer-schedules
Tools/                   # офлайн-утилиты (в приложение не входят)
  BuildChechenLexicon/   # SwiftPM: конвейер словаря (build/coverage/selftest)
  import_dosham.py · import_wikipedia.py · export_corpus.py
  export_russian_words.py · generate_review.py
  palochka_audit.py · palochka_canonicalize.py
  char_inventory.py · cyr_check.py
docs/                    # SPEC, планы, исследования, гайды, REVIEW-salgiri
.github/workflows/build.yml  # CI: SPM build+self-check, Xcode build, pipeline tests
```

ВАЖНО про Xcode-проект: используется `fileSystemSynchronizedGroups` — все
файлы из `Aza/` компилируются автоматически, явных списков в pbxproj нет.
Новые .swift подхватываются из папки; не-исходники копируются в бандл как
ресурсы (так попадает chechen-lexicon.tsv).

## 3. Два прототипа и их статус

1. **`Aza/` (Xcode)** — системный прототип, рабочий инструмент:
   хоткей ⌘⇧A (тестовая вставка), монитор слов, трёхстадийная коррекция
   ru/en/ce с защитой чеченских слов, отмена, исключения, история буфера MVP.
2. **`Sources/Aza/` (SwiftPM)** — прототип UI острова: IslandStore/
   IslandView, PrayerSchedule, каталог молитвенных времён в Resources.
   CI собирает его (`swift build`) и гоняет `swift run Aza --self-check`.

## 4. Чеченский модуль — реализован полностью

### Конвейер словаря (`Tools/BuildChechenLexicon`, SwiftPM)
Команды: `build`, `coverage` (go/no-go ≥70%), `selftest` (диагностика).
Источники с закреплёнными ревизиями; канонизация палочки; фильтр русских
заимствований; взвешивание источников (`maxShare`) и буст лемм (`boost`).

**Итоговый словарь:** 30 845 слов / 633 КБ; held-out покрытие 87,1%
(снижение против 96% корректно — русские заимствования исключены сознательно;
см. `docs/PLAN-chechen.md` §2). Артефакт: `Aza/Resources/chechen-lexicon.tsv`
+ manifest.json.

### Источники (все одобрены авторами / совместимы)
| Источник | Ревизия | Лицензия |
|---|---|---|
| lingtrain/chechen-russian (30 443 пары) | 296c9a27 | ✅ разрешение автора |
| laamxo/dosham (10 классических словарей, ce→ru, boost×3) | bb08cf1c | ✅ одобрение автора |
| Чеченская Википедия 20231101.ce (12k статей) | b04c8d1c | CC BY-SA → атрибуция при релизе |
| pyspellchecker ru (19 871 слово — фильтр) | пакет 0.9.x | MIT |

### Движок коррекции: фиксированный порядок в `directCorrection`
1. **Нормализация палочки** — гипотезы подмен; принимается единственный
   вариант, существующий в словаре; без словаря — legacy-жадная замена.
2. **en→ru ремап** → если результат валидно-русский:
   `firstKeyAlternativeIsChechen` — замена/пропуск ПЕРВОЙ клавиши даёт
   частотное (≥10) чеченское слово → НЕОДНОЗНАЧНО, не исправлять.
3. **Опечаточная стадия** (настройка OFF по умолчанию): кириллица, длина ≥4,
   нет в чеченском словаре, не русское слово, ровно один сосед на расстоянии 1
   с сохранением первой буквы, кандидат не имя собственное.
4. **guard looksChechen** — маркеры (ӏ хь къ кх аь оь уь юь яь) или слово
   в словаре → латинизировать нельзя.
5. **ru→en ремап** + abstention `hasOneEditMatch(of:)` true → nil.

### Отмена и пользовательские списки
- Двойной правый Shift (<0,7 c): откат последнего исправления тем же
  AX-механизмом замены (текст перед кареткой обязан совпасть) + исходное
  слово в never-correct. Хранится одна последняя правка.
- Списки: `~/Library/Application Support/Aza/user-words.json`,
  форма хранения — нижний регистр + каноническая палочка.

## 5. Этап 2: буфер обмена — MVP реализован

- **Монитор** (`PasteboardMonitor`): changeCount каждые 0,5 с; пропуск
  Concealed/Transient/AutoGenerated; исключения 1Password/KeeWeb/LastPass.
- **Хранилище** (`ClipboardStore`): AES-GCM (CryptoKit), ключ 256 бит в
  Keychain (service `com.tmmt.Aza.clipboard`, account `history-key`,
  WhenUnlockedThisDeviceOnly); файл Application Support/Aza/
  clipboard-history.bin; дедупликация move-to-top; лимиты 200 × 100k.
- **Избранное**: `isFavorite: Bool?` — переживает перезагрузку и prune
  (prune пропускает favorite); self-test это проверяет.
- **Поиск**: живой фильтр, избранное сверху.
- **Вставка в активное поле**: NSApp.hide → 180 мс → AX-insert
  (secure отсечён), буфер обновляется всегда как запасной путь.
- **Настройки**: тумблер сбора (default ON), воздержание при
  неоднозначности (default ON), опечатки (default OFF).
- **Self-test при старте Debug**: раундтрип, plaintext не на диске,
  tamper игнорируется, избранное переживает reload/prune.

## 6. КРИТИЧЕСКИЙ ИНВАРИАНТ: палочка

У палочки минимум ЧЕТЫРЕ кодовые точки-подмены, и они обязаны
обрабатываться синхронно в ДВУХ местах:

| Символ | Кодовая точка | Где встречается |
|---|---|---|
| `ӏ` | U+04CF | канон проекта (везде создаём только её) |
| `Ӏ` | U+04C0 | заглавная форма |
| `І` | U+0406 | **корпус lingtrain кодирует ею палочку** (103 928!) |
| `і` | U+0456 | появляется при lowercasing U+0406 |

Таблицы подмен:
- `Tools/…/ChechenLexiconCore/Palochka.swift::substitutions`
- `Aza/Features/Layout/LayoutCorrectionEngine.swift::palochkaLookalikes`
- плюс `ChechenLexicon.replacingUkrainianI` (нормализация ввода)

Меняли одно место — забудьте второе, получаете ровно тот класс багов,
который уже ловили дважды. Контроль: `python3 Tools/palochka_audit.py .`

## 7. Верификация и команды

```bash
cd "/Users/tmmt/Documents/Code projects/Aza/Aza"

# Xcode-приложение (системный прототип)
xcodebuild -project Aza.xcodeproj -scheme Aza -configuration Debug \
  -destination 'platform=macOS,arch=arm64' CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO build

# SPM-прототип острова + self-check
swift build && swift run Aza --self-check

# Конвейер словаря: тесты, сборка, покрытие
cd Tools/BuildChechenLexicon
swift test
swift run BuildChechenLexicon build --config config.json --out out_lexicon
swift run BuildChechenLexicon coverage --lexicon out_lexicon/lexicon.tsv \
  --eval datasets/heldout_eval.txt

# Аудит палочки по всему репо
python3 Tools/palochka_audit.py .
```

Смоук-запуск приложения (DEBUG-ассерты выполняются при старте).
ВАЖНО: сначала остановить уже запущенную Aza (второй экземпляр сам выйдет
из-за single-instance guard, и смоук покажет ложный FAIL), а убивать —
только pkill по пути бинарника: `kill %1` в неинтерактивной оболочке
убивает обёртку, а процесс Aza утекает — четыре утёкших экземпляра дали
баг «привет привет привет привет» (гонка мониторов слов).
```bash
pkill -f "Products/Debug/Aza.app/Contents/MacOS/Aza"; sleep 1
BIN=$(find ~/Library/Developer/Xcode/DerivedData/Aza-*/Build/Products/Debug \
  -name Aza -type f -perm +111 | head -1)
"$BIN" & sleep 4
pgrep -qf "Products/Debug/Aza" && echo "SMOKE OK" || echo "SMOKE FAIL"
pkill -f "Products/Debug/Aza.app/Contents/MacOS/Aza"
```

## 8. Грабли (уже наступали — не повторять)

1. **Инкрементальная сборка SwiftPM иногда отдаёт старый бинарник** после
   правок ядра. Признак: тесты зелёные, а поведение CLI прежнее.
   Лечение: `rm -rf .build` и пересборка.
2. **`.gitignore` и регистронезависимая ФС macOS**: шаблон `sources/`
   зацепил папку `Sources/` с кодом конвейера — коммит вышел без исходников.
   Папки датасетов называть иначе (сейчас `datasets/`).
3. **Многострочный python через `python3 -c "…"` искажается интеграцией
   терминала** — писать во временный файл-скрипт и запускать его.
4. **git без `--no-pager` зависает** в пейджере.
5. Путь проекта содержит пробел — всегда в кавычках.
6. `@Published` / `ObservableObject` требуют явного `import Combine`.
7. `Scene` не имеет `.onAppear` — старт мониторов в init или View.
8. У палочки 4 кодовых точки (см. §6) — проверять литералы глазами нельзя,
   только аудитом.

## 9. Дорожная карта (приоритизированная)

### P0 — ручное тестирование владельцем
Включить тумблеры в меню и проверить три стадии коррекции в TextEdit:
`[mj`→хьо, `1алам`→ӏалам, опечатка словарного слова (при включённых
опечатках), отмена двойным правым Shift, история буфера + вставка.

### P1 — завершение Этапа 2 (буфер), см. docs/PLAN-stage2-clipboard.md
Сделано 25.08: пагинация «Показать ещё», удаление через контекстное меню
+ «Отменить» (5 с, восстановление по createdAt). Осталось:
- time-based retention; изображения/файлы/RTF; Quick Look;
- Delete-клавиша и массовое ⌘A+Delete (нужна модель выделения);
- настраиваемый пользователем список исключаемых приложений.

### P2 — Этап 3: диктовка
WhisperKit (SPM) как основной путь; горячая клавиша push-to-talk;
вставка через TextInsertion; модели из раздела 5.4 спецификации.
Альтернатива для «быстрого профиля»: FluidAudio/Parakeet (проверить русский).

### P3 — Этап 4: намаз
Провайдер на adhan-swift (MIT) + провайдер расписаний ДУМ; уведомления;
азан со свободной лицензией (искать через Awesome-Muslims).

### Технический долг (по мере касания)
- тестовая цель для Xcode-приложения (чистые функции движка и лексикона);
- реактивный счётчик исключений в меню (UserWordLists не Observable);
- откат N последних слов вместо одного;
- фильтр ложно-чеченских русских омографов тоньше списка pyspellchecker.

## 10. Релизный чек-лист (когда дойдём)
Спецификация §14: Developer ID → hardened runtime → DMG → notarization →
Sparkle. THIRD_PARTY: lingtrain ✅разрешение, dosham ✅одобрение,
Wikipedia CC BY-SA (атрибуция), pyspellchecker MIT, adhan-swift MIT.
App Store не используется.

## 11. Правила работы агента
1. После каждого шага — ревью и пересборка; владелец просил перепроверять.
2. Коммиты осмысленные (`feat:`/`fix:`/`docs:`), push после зелёной сборки.
3. Приватность: ничего о пользователе наружу; диагностические файлы —
   только локально.
4. GPL/CC BY-NC код не копировать (boring.notch, InputSourcePro, PasteBar).
5. Новую кодовую точку палочки добавлять сразу в Palochka.substitutions
   И palochkaLookalikes + прогон palochka_audit.py.

