import Foundation

/// Поколение отменяется при блокировке и очистке: уже начатый async-прогон
/// может завершиться после cancel(), но не имеет права публиковать результат.
struct DictationSession {
    private(set) var generation = UUID()
    var isLocked = false
    var isDeletingModels = false

    var canStart: Bool { !isLocked && !isDeletingModels }

    mutating func invalidate() { generation = UUID() }

    func accepts(_ generation: UUID) -> Bool {
        canStart && self.generation == generation
    }
}

/// Чистая логика фильтров диктовки. Вынесена из DictationController,
/// чтобы тестироваться без WhisperKit (тест-таргет собирает явный список
/// файлов и пакет не линкует).
enum DictationFilters {

    /// Whisper на тишине галлюцинирует связный текст («Субтитры сделал…»),
    /// поэтому запись без единого громкого окна не распознаём вовсе — это
    /// заодно экономит прогон модели.
    // ponytail: энергетический порог вместо VAD-модели; ослабить по логам,
    // если тихую речь начнёт принимать за тишину.
    static let speechRMSThreshold: Float = 0.005

    static func hasSpeech(_ samples: [Float]) -> Bool {
        let window = 1600 // 100 мс при 16 кГц
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var energy: Float = 0
            for sample in samples[index..<end] { energy += sample * sample }
            if (energy / Float(end - index)).squareRoot() >= speechRMSThreshold {
                return true
            }
            index = end
        }
        return false
    }

    /// Свои слова из настройки: строка через запятую или с новой строки.
    static func words(fromCustomList raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Звуки-паразиты (приём Handy): режутся только НЕ-слова — междометия
    /// вроде «эм»/«э-э»/"uh", которые не бывают осмысленным текстом ни в
    /// русском, ни в английском (§5.2 поддерживает только их). Настоящие
    /// слова-паразиты («ну», «вот», "like") не трогаем принципиально:
    /// у Handy та же логика fail-closed — португальское "um" оказалось
    /// настоящим словом, вырезание съедало текст.
    /// Одиночные «э» и "err" намеренно отсутствуют: «Э, постой» — живое
    /// междометие, "to err is human" — настоящий глагол.
    static let fillerSounds: Set<String> = [
        "эм", "эмм", "эммм", "ээ", "эээ", "э-э", "э-э-э",
        "а-а", "а-а-а", "ммм", "м-м", "м-м-м", "мхм", "угу-м",
        "uh", "uhh", "um", "umm", "ummm", "erm",
        "hmm", "hm", "mhm", "mm-hmm",
    ]

    /// Переписывает текст по токенам, СОХРАНЯЯ пробельные разделители
    /// (перенос строки из диктовки не должен стать пробелом). Токен —
    /// непробельный run; transform возвращает замену или nil — «выбросить».
    /// При выбросе из двух соседних разделителей выживает тот, где есть
    /// перенос строки (перенос — структура текста: «готово эм\nдалее» →
    /// «готово\nдалее»), иначе предыдущий; двойного пробела не остаётся.
    static func rewriteTokens(in text: String,
                              _ transform: (Substring) -> String?) -> String {
        var result = ""
        var index = text.startIndex

        func readRun(_ belongs: (Character) -> Bool) -> Substring {
            let start = index
            while index < text.endIndex, belongs(text[index]) {
                index = text.index(after: index)
            }
            return text[start..<index]
        }

        // Разделитель, накопленный ПЕРЕД следующим токеном (ещё не записан).
        var pending = readRun { $0.isWhitespace }
        while index < text.endIndex {
            let token = readRun { !$0.isWhitespace }
            let following = readRun { $0.isWhitespace }
            if let replaced = transform(token) {
                result += pending
                result += replaced
                pending = following
            } else {
                pending = following.contains(where: \.isNewline) ? following : pending
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Убирает звуки-паразиты по границам слов; прилипшая пунктуация
    /// уходит вместе со звуком («Эм, привет» → «Привет»). Заглавная БУКВА
    /// начала восстанавливается даже за открывающей пунктуацией («Эм,
    /// «привет»» → «Привет»»), если оригинал начинался с заглавной.
    static func removingFillerSounds(from text: String) -> String {
        let result = rewriteTokens(in: text) { token in
            let bare = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return bare.isEmpty || !fillerSounds.contains(bare) ? String(token) : nil
        }
        guard result != text else { return text }
        var restored = result
        if let originalFirst = text.first(where: \.isLetter), originalFirst.isUppercase,
           let index = restored.firstIndex(where: \.isLetter),
           restored[index].isLowercase {
            restored.replaceSubrange(index...index,
                                     with: restored[index].uppercased())
        }
        return restored
    }

    /// Fuzzy-притяжка своих слов (приём Handy): Whisper коверкает имена и
    /// термины даже с подсказкой в prompt — пост-обработкой заменяем токен
    /// на пользовательское слово, когда он «почти совпал». Пороги
    /// консервативные (ложная замена настоящего слова хуже пропущенной
    /// правки): длина ≥ 4, расстояние Левенштейна ≤ 1, с 7 букв — ≤ 2.
    /// Сравнение — в каноне палочки и нижнем регистре; точное каноническое
    /// совпадение тоже заменяется формой пользователя (чинит «1алам» и
    /// регистр). Многословные записи списка пропускаются.
    // ponytail: без фонетики и n-грамм — добавить, если по логам замен
    // окажется мало.
    static func applyingCustomWords(to text: String, words: [String]) -> String {
        let candidates = words
            .filter { !$0.contains(where: \.isWhitespace) && $0.count >= 4 }
            .map { (key: LayoutCorrectionEngine.canonicalPalochkaForm(of: $0), form: $0) }
        guard !candidates.isEmpty else { return text }

        return rewriteTokens(in: text) { token in
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            guard bare.count >= 4 else { return String(token) }
            let key = LayoutCorrectionEngine.canonicalPalochkaForm(of: bare)
            var best: (distance: Int, form: String)?
            var tie = false
            for candidate in candidates {
                let allowed = key.count >= 7 ? 2 : 1
                guard let distance = levenshtein(key, candidate.key, cap: allowed) else {
                    continue
                }
                if let current = best {
                    if distance < current.distance {
                        best = (distance, candidate.form)
                        tie = false
                    } else if distance == current.distance,
                              candidate.form != current.form {
                        // Два РАЗНЫХ кандидата на одном расстоянии:
                        // выбирать по порядку списка — произвол, честнее
                        // не трогать («Рамиль» при «Камиль, Самиль»).
                        tie = true
                    }
                } else {
                    best = (distance, candidate.form)
                }
            }
            guard let best, !tie, best.form != bare else { return String(token) }
            // Пунктуация по краям токена остаётся на месте.
            let prefix = token.prefix { $0.isPunctuation }
            let suffix = token.reversed().prefix { $0.isPunctuation }.reversed()
            return String(prefix) + best.form + String(suffix)
        }
    }

    /// Расстояние Левенштейна с потолком: превысило cap — nil (дальше
    /// считать незачем). Классическое ДП по двум строкам таблицы.
    static func levenshtein(_ a: String, _ b: String, cap: Int) -> Int? {
        let left = Array(a), right = Array(b)
        guard abs(left.count - right.count) <= cap else { return nil }
        guard !left.isEmpty, !right.isEmpty else {
            let distance = max(left.count, right.count)
            return distance <= cap ? distance : nil
        }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return nil }
            swap(&previous, &current)
        }
        return previous[right.count] <= cap ? previous[right.count] : nil
    }

    /// Сегменты-галлюцинации по классической эвристике openai/whisper:
    /// модель сама считает окно тишиной (noSpeechProb > 0.6) и при этом
    /// не уверена в тексте (avgLogprob < −1.0) — такой текст выдуман.
    /// WhisperKit эти сегменты не выбрасывает (fallback «silence»
    /// оставляет текст), поэтому чистим сами.
    static func reliableText(
        segments: [(text: String, avgLogprob: Float, noSpeechProb: Float)]
    ) -> String {
        segments
            .filter { $0.noSpeechProb <= 0.6 || $0.avgLogprob >= -1.0 }
            .map(\.text)
            .joined()
            .replacingOccurrences(of: "<\\|[^|]*\\|>", with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
