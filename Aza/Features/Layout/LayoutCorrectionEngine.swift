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

    /// Pure remap of a word typed on QWERTY into ЙЦУКЕН.
    /// Returns nil if any character has no mapping (e.g. already Cyrillic).
    static func remapped(_ word: String) -> String? {
        guard !word.isEmpty else { return nil }
        var result = ""
        for character in word {
            guard let mapped = qwertyToRussian[Character(character.lowercased())] else { return nil }
            result.append(character.isUppercase ? Character(mapped.uppercased()) : mapped)
        }
        return result
    }

    /// Offers a correction only when the original is not a valid English word
    /// and the remap yields a valid Russian word.
    @MainActor
    static func correction(for word: String) -> String? {
        // ponytail: naive spellchecker gate, no confidence scoring; replace with
        // the real RU/EN/Chechen classifier in Stage 5.
        guard word.count >= 3,
              let candidate = remapped(word),
              !isValidWord(word, language: "en"),
              isValidWord(candidate, language: "ru") else { return nil }
        return candidate
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
