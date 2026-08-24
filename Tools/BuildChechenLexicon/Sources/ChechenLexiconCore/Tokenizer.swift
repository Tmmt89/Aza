/// Разбиение текста на слова.
///
/// Правило: граница слова — не-буква, но цифра 1 внутри кириллического слова
/// границей НЕ считается (это подмена палочки). Латинские I и l — буквы,
/// поэтому они и так остаются внутри слов естественным образом.
public struct Tokenizer {
    public init() {}

    public func tokens(in text: String) -> [String] {
        var result: [String] = []
        var current: [Character] = []
        let chars = Array(text)

        func flush() {
            if !current.isEmpty {
                result.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }

        for (i, c) in chars.enumerated() {
            if c.isLetter {
                current.append(c)
            } else if Palochka.isSubstitution(c), attaches(at: i, chars: chars, current: current) {
                current.append(c)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Подмена приклеивается к слову, если текущее накопленное слово уже
    /// кириллическое или следующий непробельный символ кириллический.
    /// Так «г1ала» — одно слово, а «17:35» не порождает ложных склеек.
    private func attaches(at index: Int, chars: [Character], current: [Character]) -> Bool {
        if current.contains(where: Palochka.isCyrillic) { return true }
        var j = index + 1
        while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" { j += 1 }
        return j < chars.count && Palochka.isCyrillic(chars[j])
    }
}
