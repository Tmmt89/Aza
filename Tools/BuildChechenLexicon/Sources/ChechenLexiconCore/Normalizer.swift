/// Нормализация палочки.
public enum Normalizer {

    /// Каноническая форма для КОРПУСА: все подмены (1, I, l) заменяются
    /// настоящей палочкой. Корпус грязный — часть слов написана «через
    /// единицу», поэтому нормализуем сам корпус, чтобы в словаре не было
    /// дублей вида «г1ала» и «гӏала».
    public static func canonical(_ word: String) -> String {
        guard word.contains(where: { Palochka.isSubstitution($0) || Palochka.isAnyPalochka($0) }) else {
            return word
        }
        return String(word.map { c -> Character in
            if Palochka.isSubstitution(c) || c == Palochka.uppercaseCharacter {
                return Palochka.character
            }
            return c
        })
    }

    /// Смесь кириллицы и латиницы — почти наверняка подмены палочки:
    /// нормальных слов из двух алфавитов не бывает. Сильная улика,
    /// более весомая, чем одиночная цифра.
    public static func isMixedAlphabet(_ word: String) -> Bool {
        Palochka.containsCyrillic(word) && Palochka.containsLatin(word)
    }

    /// Гипотезы для ТОЧНОЙ нормализации пользовательского ввода: каждая
    /// подмена либо палочка, либо остаётся как есть. Для слова с k подменами
    /// возвращается 2^k вариантов (обычно два-четыре).
    ///
    /// ВАЖНО: цифру 1 в конце слова нельзя автоматически считать палочкой —
    /// это может быть нумерация. Выбор среди гипотез делает словарь.
    public static func hypotheses(for word: String) -> [String] {
        let positions = Array(word.indices.filter { Palochka.isSubstitution(word[$0]) })
        guard !positions.isEmpty else { return [word] }
        precondition(positions.count <= 12, "слишком много подмен для перебора")

        var results: [String] = []
        results.reserveCapacity(1 << positions.count)
        for mask in 0..<(1 << positions.count) {
            var line = ""
            for i in word.indices {
                if let p = positions.firstIndex(of: i) {
                    line.append((mask >> p) & 1 == 1 ? Palochka.character : word[i])
                } else {
                    line.append(word[i])
                }
            }
            results.append(line)
        }
        return results
    }
}
