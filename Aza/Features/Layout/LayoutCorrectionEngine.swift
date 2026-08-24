import AppKit

enum LayoutCorrectionEngine {
    /// QWERTY key → ЙЦУКЕН letter (lowercase; uppercase derived per character).
    private static let qwertyToRussian: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т",
        "m": "ь", ",": "б", ".": "ю", "`": "ё",
    ]

    private static let russianToQwerty = Dictionary(
        uniqueKeysWithValues: qwertyToRussian.map { ($1, $0) }
    )

    /// Chechen orthography markers: a Cyrillic word containing one of these is
    /// treated as Chechen — never remapped to Latin, and accepted as a valid
    /// correction target even though it fails the Russian spellchecker.
    private static let chechenMarkers = ["ӏ", "хь", "къ", "кх", "аь", "оь", "уь", "юь", "яь"]

    /// Characters commonly typed instead of the Chechen palochka Ӏ.
    private static let palochkaLookalikes: Set<Character> = ["1", "I", "l"]

    /// QWERTY keys that produce Cyrillic letters (х ъ ж э ё) and thus belong to
    /// a word typed in the wrong layout, plus "1" for palochka normalization.
    static let wordPunctuation: Set<Character> = ["[", "]", ";", "'", "`", "1"]

    /// Pure remap between layouts. Returns nil if any character has no mapping.
    static func remapped(_ word: String, table: [Character: Character]) -> String? {
        guard !word.isEmpty else { return nil }
        var result = ""
        for character in word {
            guard let mapped = table[Character(character.lowercased())] else { return nil }
            result.append(character.isUppercase ? Character(mapped.uppercased()) : mapped)
        }
        return result
    }

    static func remappedToRussian(_ word: String) -> String? {
        remapped(word, table: qwertyToRussian)
    }

    static func remappedToLatin(_ word: String) -> String? {
        remapped(word, table: russianToQwerty)
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
        // ponytail: naive spellchecker + marker gate, no confidence scoring;
        // replace with the real RU/EN/Chechen classifier in Stage 5.
        if let normalized = normalizedPalochka(word) {
            return (normalized, nil)
        }

        if let russian = remappedToRussian(word) {
            guard word.count >= 3,
                  !isValidWord(word, language: "en"),
                  isValidWord(russian, language: "ru") || looksChechen(russian) else { return nil }
            return (russian, "ru")
        }

        // Chechen Cyrillic words fail the Russian spellchecker — they must
        // never be "fixed" into Latin the way Punto-style switchers do.
        guard !looksChechen(word) else { return nil }

        if let latin = remappedToLatin(word) {
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
