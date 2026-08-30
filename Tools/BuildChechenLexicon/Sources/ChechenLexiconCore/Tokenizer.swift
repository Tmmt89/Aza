/// Разбиение текста на слова.
///
/// Правило: граница слова — не-буква, но подмена палочки (1, I, l, укр. і)
/// границей НЕ считается, если приклеивается к кириллице. Подмены-буквы
/// проверяются ДО isLetter: иначе чистые I/l-раны (римские II, III, «Il»)
/// становились бы токенами и канонизировались в мусорные «ӏӏ»/«ӏӏӏ» —
/// тот же класс, что дал «ӏ» с частотой 1108 в поставленном словаре.
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
            if Palochka.isSubstitution(c) {
                if attaches(at: i, chars: chars, current: current) {
                    current.append(c)
                } else if c.isLetter, continuesLatin(at: i, chars: chars, current: current) {
                    current.append(c)
                } else {
                    flush()
                }
            } else if c.isLetter {
                current.append(c)
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    /// Подмена приклеивается к слову, если текущее накопленное слово уже
    /// кириллическое или НЕПОСРЕДСТВЕННО следующий символ кириллический.
    /// Так «г1ала» — одно слово, а «17:35» не порождает ложных склеек.
    /// Пробелы НЕ перескакиваются: «1 август» — это номер списка и слово,
    /// а прежний скан через пробел склеивал единицу в отдельный токен «1»,
    /// который канонизация превращала в мусорное слово «ӏ» (частота 1108
    /// в поставленном словаре).
    private func attaches(at index: Int, chars: [Character], current: [Character]) -> Bool {
        if current.contains(where: Palochka.isCyrillic) { return true }
        let j = index + 1
        return j < chars.count && Palochka.isCyrillic(chars[j])
    }

    /// I/l продолжают ЛАТИНСКОЕ слово (hello, world): сосед — латинская
    /// буква, НЕ являющаяся подменой. «Il»/«II»/«III» так не спасаются —
    /// их соседи сами подмены, и токен из одних подмен не рождается.
    private func continuesLatin(at index: Int, chars: [Character], current: [Character]) -> Bool {
        func plainLatin(_ c: Character) -> Bool {
            Palochka.isLatinLetter(c) && !Palochka.isSubstitution(c)
        }
        if let last = current.last, plainLatin(last) { return true }
        let j = index + 1
        return j < chars.count && plainLatin(chars[j])
    }
}
