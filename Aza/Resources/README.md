# Ресурсы приложения

- `chechen-lexicon.tsv` — частотный словарь чеченских слов, собран конвейером
  `Tools/BuildChechenLexicon` из корпуса `lingtrain/chechen-russian`.
  Формат: `слово\tчастота\tфлаг «только с заглавной»`, кодировка UTF-8,
  палочка канонизирована к U+04CF.

⚠️ Лицензия корпуса на момент сборки НЕ подтверждена автором. Артефакт
находится в репозитории только для локальной разработки; перед публичным
релизом (DMG) нужно письменное разрешение или замена источника.
Подробности: `docs/PLAN-chechen.md`, разделы про лицензию артефакта.
Пересборка после обновления корпуса:

```bash
cd Tools/BuildChechenLexicon
swift run BuildChechenLexicon build --config config.json --out out_lexicon
cp out_lexicon/lexicon.tsv ../../Aza/Resources/chechen-lexicon.tsv
```
