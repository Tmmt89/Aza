/// Палочка — буква. Подмены: цифра 1, латинские I и l.
public enum Palochka {

    /// Настоящая чеченская буква «палочка» в нижнем регистре (U+04CF).
    /// ВАЖНО: у палочки ДВА кодовых пункта — заглавная U+04C0 («Ӏ») и
    /// строчная U+04CF («ӏ»). Корпус смешивает их произвольно, поэтому всё
    /// канонизируется к строчной — иначе в словаре будут невидимые дубли.
    public static let character: Character = "\u{04CF}"

    /// Заглавная палочка (U+04C0).
    public static let uppercaseCharacter: Character = "\u{04C0}"

    /// Частые подмены палочки при наборе и в старых изданиях.
    /// Известные кодовые точки-близнецы:
    /// - U+0456 строчная и U+0406 ЗАГЛАВНАЯ украинская І — именно ими
    ///   корпус lingtrain кодирует палочку (103 928 вхождений!);
    /// - цифра 1 и латинские I/l — обычный пользовательский набор.
    public static let substitutions: Set<Character> = [
        "1", "I", "l", "\u{0456}", "\u{0406}",
    ]

    public static func isSubstitution(_ c: Character) -> Bool {
        substitutions.contains(c)
    }

    /// Приведение одного символа к канонической строчной палочке.
    public static func canonize(_ c: Character) -> Character {
        c == uppercaseCharacter ? character : c
    }

    public static func isAnyPalochka(_ c: Character) -> Bool {
        c == character || c == uppercaseCharacter
    }

    public static func isCyrillic(_ c: Character) -> Bool {
        // Палочка U+04C0 тоже попадает в диапазон кириллицы.
        c.unicodeScalars.allSatisfy { (0x0400...0x04FF).contains($0.value) }
    }

    public static func isLatinLetter(_ c: Character) -> Bool {
        c.isLetter && !isCyrillic(c)
    }

    public static func containsCyrillic<S: StringProtocol>(_ s: S) -> Bool {
        s.contains(where: isCyrillic)
    }

    public static func containsLatin<S: StringProtocol>(_ s: S) -> Bool {
        s.contains(where: isLatinLetter)
    }

    /// Стабильный хеш строки (djb2) — для имён файлов кэша,
    /// в отличие от hashValue, не меняется между запусками.
    public static func stableHash<S: StringProtocol>(_ s: S) -> UInt64 {
        var hash: UInt64 = 5381
        for b in s.utf8 {
            hash = (hash &* 33) &+ UInt64(b)
        }
        return hash
    }
}
