import AppKit

enum LayoutCorrectionEngine {
    /// Letter keys: QWERTY → ЙЦУКЕН. Uppercase pairs are derived from these.
    private static let letterKeys: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
    ]

    /// Punctuation keys that carry Cyrillic letters — б and ю live on the comma
    /// and period keys, so those characters are part of a word, not delimiters.
    private static let punctuationKeys: [Character: Character] = [
        "[": "х", "]": "ъ", ";": "ж", "'": "э", ",": "б", ".": "ю", "`": "ё",
    ]

    /// The same keys with Shift held, which is how Х Ъ Ж Э Б Ю Ё are typed.
    private static let shiftedPunctuationKeys: [Character: Character] = [
        "{": "Х", "}": "Ъ", ":": "Ж", "\"": "Э", "<": "Б", ">": "Ю", "~": "Ё",
    ]

    static let qwertyToRussian: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (key, value) in letterKeys {
            table[key] = value
            table[Character(key.uppercased())] = Character(value.uppercased())
        }
        table.merge(punctuationKeys) { current, _ in current }
        table.merge(shiftedPunctuationKeys) { current, _ in current }
        return table
    }()

    static let russianToQwerty: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (key, value) in qwertyToRussian {
            table[value] = key
        }
        return table
    }()

    /// Chechen orthography markers: a Cyrillic word containing one of these is
    /// treated as Chechen — never remapped to Latin, and accepted as a valid
    /// correction target even though it fails the Russian spellchecker.
    private static let chechenMarkers = ["ӏ", "хь", "къ", "кх", "аь", "оь", "уь", "юь", "яь"]

    /// Characters commonly typed instead of the Chechen palochka Ӏ.
    private static let palochkaLookalikes: Set<Character> = ["1", "I", "l"]

    /// Trailing characters that are more likely real punctuation than the
    /// letters б/ю, so a word ending in them is retried without them.
    private static let trailingPunctuation: Set<Character> = [",", "."]

    /// Non-letter characters that still belong to a word being typed.
    static let wordPunctuation: Set<Character> = {
        var set = Set(punctuationKeys.keys)
        set.formUnion(shiftedPunctuationKeys.keys)
        set.insert("1") // palochka look-alike
        return set
    }()

    /// Pure remap between layouts. Returns nil if any character has no mapping.
    static func remapped(_ word: String, table: [Character: Character]) -> String? {
        guard !word.isEmpty else { return nil }
        var result = ""
        for character in word {
            guard let mapped = table[character] else { return nil }
            result.append(mapped)
        }
        return result
    }

    static func looksChechen(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return chechenMarkers.contains { lowered.contains($0) }
    }

    /// 1/I/l inside a Cyrillic word → Ӏ (Chechen palochka). Nil when not applicable.
    static func normalizedPalochka(_ word: String) -> String? {
        guard word.contains(where: isCyrillic),
              word.contains(where: { palochkaLookalikes.contains($0) }) else { return nil }
        return String(word.map { palochkaLookalikes.contains($0) ? "Ӏ" : $0 })
    }

    private nonisolated static func isCyrillic(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { (0x400...0x4FF).contains($0.value) } ?? false
    }

    /// The correction for a finished word, if any, and the input-source language
    /// to switch to afterwards (nil — keep the current layout).
    @MainActor
    static func correction(for word: String) -> (text: String, inputLanguage: String?)? {
        if let direct = directCorrection(for: word) { return direct }

        // "ghbdtn," is привет followed by a comma, not a word ending in б.
        var core = word
        var suffix = ""
        while let last = core.last, trailingPunctuation.contains(last) {
            suffix.insert(last, at: suffix.startIndex)
            core.removeLast()
        }
        guard !suffix.isEmpty, let correction = directCorrection(for: core) else { return nil }
        return (correction.text + suffix, correction.inputLanguage)
    }

    @MainActor
    private static func directCorrection(for word: String) -> (text: String, inputLanguage: String?)? {
        // ponytail: naive spellchecker + marker gate, no confidence scoring;
        // replace with the real RU/EN/Chechen classifier in Stage 5.
        if let normalized = normalizedPalochka(word) {
            return (normalized, nil)
        }

        if let russian = remapped(word, table: qwertyToRussian) {
            guard word.count >= 3,
                  !isValidWord(word, language: "en"),
                  isValidWord(russian, language: "ru") || looksChechen(russian) else { return nil }
            return (russian, "ru")
        }

        // Chechen Cyrillic words fail the Russian spellchecker — they must
        // never be "fixed" into Latin the way Punto-style switchers do.
        guard !looksChechen(word) else { return nil }

        if let latin = remapped(word, table: russianToQwerty) {
            guard word.count >= 3,
                  !isValidWord(word, language: "ru"),
                  isValidWord(latin, language: "en") else { return nil }
            return (latin, "en")
        }

        return nil
    }

    @MainActor
    private static func isValidWord(_ word: String, language: String) -> Bool {
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelled.location == NSNotFound
    }
}
