import Foundation

/// Частотный словарь чеченских слов, собранный конвейером
/// Tools/BuildChechenLexicon (артефакт lexicon.tsv в ресурсах бандла).
///
/// Загружается лениво при первом обращении: пока пользователь не коснулся
/// чеченского текста, память не расходуется. Если ресурс не найден
/// (словарь убрали из сборки из-за лицензии), остаётся пустым — движок
/// коррекции откатывается на поведение без словаря.
@MainActor
final class ChechenLexicon {
    static let shared = ChechenLexicon()

    /// Все слова в нижнем регистре, каноническая палочка U+04CF.
    private(set) var words: Set<String> = []
    /// Частоты слов из артефакта конвейера.
    private(set) var frequencies: [String: Int] = [:]
    /// Слова, встречавшиеся в корпусе ТОЛЬКО с заглавной — вероятные имена
    /// собственные; автокоррекцией не трогаются.
    private(set) var capitalOnlyWords: Set<String> = []

    /// Минимальная частота слова, чтобы оно считалось «серьёзной»
    /// альтернативой в предохранителях неоднозначности. Редкие записи
    /// (шум корпуса, OCR) предохранители не триггерят.
    static let ambiguityMinFrequency = 10

    private init() {
        guard let url = Bundle(for: ChechenLexicon.self)
            .url(forResource: "chechen-lexicon", withExtension: "tsv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        for line in content.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = fields.first, !first.isEmpty else { continue }
            let word = String(first)
            words.insert(word)
            if fields.count > 1, let count = Int(fields[1]) {
                frequencies[word] = count
            }
            if fields.count > 2, fields[2] == "1" {
                capitalOnlyWords.insert(word)
            }
        }
    }

    /// Словарь загружен и им можно пользоваться.
    var isAvailable: Bool { !words.isEmpty }

    func frequency(of word: String) -> Int {
        frequencies[word.lowercased()] ?? 0
    }

    func isFrequent(_ word: String) -> Bool {
        frequency(of: word) >= Self.ambiguityMinFrequency
    }

    /// Есть ли у слова из ЧЕЧЕНСКОГО словаря сосед в одну правку от `word`?
    /// Используется как признак неоднозначности перед латинизацией.
    func hasOneEditMatch(of word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.count >= 4 else { return false }

        // Для предохранителя неоднозначности важны только частотные слова:
        // редкие записи словаря (шум Википедии, OCR) не считаются уликой.
        func significant(_ variant: String) -> Bool {
            isFrequent(variant) || isFrequent(canonicalTwins(in: variant))
        }
        let characters = Array(lower)

        for index in characters.indices {
            var variant = characters
            variant.remove(at: index)
            if significant(String(variant)) { return true }
            for letter in Self.alphabet where letter != characters[index] {
                var substitution = characters
                substitution[index] = letter
                if significant(String(substitution)) { return true }
            }
        }
        for index in 0...characters.count {
            for letter in Self.alphabet {
                var variant = characters
                variant.insert(letter, at: index)
                if significant(String(variant)) { return true }
            }
        }
        for index in characters.indices.dropLast() {
            var variant = characters
            variant.swapAt(index, index + 1)
            if significant(String(variant)) { return true }
        }
        return false
    }

    /// Сводит украинские І (U+0456/U+0406) к канонической палочке —
    /// чтобы проверка значимости не зависела от кодовой точки ввода.
    func canonicalTwins(in string: String) -> String {
        Self.replacingUkrainianI(in: string)
    }

    /// Регистронезависимая проверка: вход может содержать любую из двух
    /// кодовых точек палочки — lowercased() сводит U+04C0 к U+04CF.
    func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }

    /// Алфавит для генерации кандидатов в одну правку: русские буквы + палочка.
    private static let alphabet = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюяӏ")

    private static let ukrainianITwins: Set<Character> = ["\u{0456}", "\u{0406}"]
    private static let canonicalPalochka: Character = "\u{04CF}"

    private static func replacingUkrainianI(in string: String) -> String {
        String(string.map { ukrainianITwins.contains($0) ? canonicalPalochka : $0 })
    }

    /// Единственный сосед слова на расстоянии одной правки (удаление,
    /// замена, вставка или транспозиция соседних букв) — или nil.
    ///
    /// Условия безопасности (PLAN-chechen §3.3):
    /// - кандидаты ищутся только среди слов словаря;
    /// - имена собственные (capitalOnly) никогда не предлагаются;
    /// - если кандидатов 0 или больше одного — возвращается nil.
    func oneEditNeighbor(of word: String) -> String? {
        // Украинские І (U+0456/U+0406) — не «гипотезы», а грязный ввод:
        // их сразу сводим к канону, иначе кандидаты унаследуют близнеца
        // и никогда не совпадут со словарём. Цифра 1 и латинские I/l
        // остаются как есть — это осмысленные варианты набора.
        let lower = Self.replacingUkrainianI(in: word).lowercased()
        guard lower.count >= 4 else { return nil }

        let characters = Array(lower)
        var candidates = Set<String>()

        func register(_ variant: [Character]) {
            let candidate = String(variant)
            if candidate != lower, words.contains(candidate),
               !capitalOnlyWords.contains(candidate) {
                candidates.insert(candidate)
            }
        }

        // Удаление.
        for index in characters.indices {
            var variant = characters
            variant.remove(at: index)
            register(variant)
        }
        // Замена.
        for index in characters.indices {
            for letter in Self.alphabet where letter != characters[index] {
                var variant = characters
                variant[index] = letter
                register(variant)
            }
        }
        // Вставка.
        for index in 0...characters.count {
            for letter in Self.alphabet {
                var variant = characters
                variant.insert(letter, at: index)
                register(variant)
            }
        }
        // Транспозиция соседних букв.
        for index in characters.indices.dropLast()
        where characters[index] != characters[index + 1] {
            var variant = characters
            variant.swapAt(index, index + 1)
            register(variant)
        }

        return candidates.count == 1 ? candidates.first : nil
    }
}
