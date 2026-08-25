# Ресурсы приложения

- `chechen-lexicon.tsv` — частотный словарь чеченских слов, собран конвейером
  `Tools/BuildChechenLexicon` из корпуса `lingtrain/chechen-russian`.
  Формат: `слово\tчастота\tфлаг «только с заглавной»`, кодировка UTF-8,
  палочка канонизирована к U+04CF.

✅ **Лицензия:** автор корпуса (lingtrain) дал разрешение на использование
для создания и распространения частотного словаря в составе Aza
(подтверждено владельцем проекта 25.08.2026). Источник указывается в
разделе «О приложении» и в THIRD_PARTY при релизе.

Пересборка после обновления корпуса:

```bash
cd Tools/BuildChechenLexicon
swift run BuildChechenLexicon build --config config.json --out out_lexicon
cp out_lexicon/lexicon.tsv ../../Aza/Resources/chechen-lexicon.tsv
```
