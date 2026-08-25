import AppKit

enum LayoutCorrectionEngine {
    /// Chechen orthography markers: a Cyrillic word containing one of these is
    /// treated as Chechen — never remapped to Latin, and accepted as a valid
    /// correction target even though it fails the Russian spellchecker.
    private static let chechenMarkers = ["ӏ", "хь", "къ", "кх", "аь", "оь", "уь", "юь", "яь"]

    /// Canonical (lowercase) Chechen palochka, U+04CF.
    private static let palochka: Character = "\u{04CF}"

    /// IMPORTANT: the palochka has TWO codepoints — uppercase U+04C0 ("Ӏ")
    /// and lowercase U+04CF ("ӏ"). Keyboards and corpora mix them freely,
    /// so both must be treated as the same letter everywhere.
    private static let uppercasePalochka: Character = "\u{04C0}"

    /// Characters commonly typed instead of the Chechen palochka Ӏ.
    /// Known codepoint twins: digit 1, Latin I/l, Ukrainian lowercase І
    /// (U+0456) AND Ukrainian uppercase І (U+0406) — the lingtrain corpus
    /// encodes the palochka with the latter (103,928 occurrences!).
    private static let palochkaLookalikes: Set<Character> = [
        "1", "I", "l", "\u{0456}", "\u{0406}",
    ]

    /// Trailing characters that are more likely real punctuation than the
    /// letters б/ю, so a word ending in them is retried without them.
    private static let trailingPunctuation: Set<Character> = [",", "."]

    /// True once the system has the layouts needed to correct anything.
    @MainActor
    static var isAvailable: Bool { KeyboardLayoutMap.table(from: "en", to: "ru") != nil }

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
        // Lowercasing folds U+04C0 into U+04CF, so one check covers both.
        if lowered.contains(palochka) { return true }
        // A word present in the Chechen lexicon is Chechen even without
        // markers (e.g. "дела", "баркалла").
        if ChechenLexicon.shared.contains(word) { return true }
        return chechenMarkers.contains { lowered.contains($0) }
    }

    /// Каноническая форма слова для пользовательских списков: все подмены
    /// палочки (включая украинские І) заменяются на U+04CF, регистр нижний.
    static func canonicalPalochkaForm(of word: String) -> String {
        String(word.map { palochkaLookalikes.contains($0) ? palochka : $0 }).lowercased()
    }

    /// 1/I/l inside a Cyrillic word → canonical palochka.
    ///
    /// With a bundled lexicon this is hypothesis checking (PLAN-chechen §3.2):
    /// every lookalike is either the palochka or stays as typed; the change is
    /// applied only when EXACTLY ONE variant exists in the lexicon. Zero or
    /// several matches → the word is left untouched.
    ///
    /// Without a lexicon resource the legacy greedy rule applies: all
    /// lookalikes are replaced (protection still comes from looksChechen).
    static func normalizedPalochka(_ word: String) -> String? {
        // Пользователь отменил исправление этого слова — больше не трогаем.
        guard !UserWordLists.shared.isNeverCorrect(word) else { return nil }
        guard word.contains(where: isCyrillic),
              word.contains(where: { palochkaLookalikes.contains($0) }) else { return nil }

        if ChechenLexicon.shared.isAvailable {
            let matches = palochkaHypotheses(for: word)
                .filter { ChechenLexicon.shared.contains($0) }
            return matches.count == 1 ? matches[0] : nil
        }

        return String(word.map {
            palochkaLookalikes.contains($0)
                ? palochka
                : ($0 == uppercasePalochka ? palochka : $0)
        })
    }

    /// All subsets of lookalike positions read as palochka, others kept as
    /// typed ("1алам" → ["1алам", "ӏалам"]). A word rarely has more than 2–4.
    private static func palochkaHypotheses(for word: String) -> [String] {
        let positions = Array(word.indices.filter { palochkaLookalikes.contains(word[$0]) })
        guard !positions.isEmpty, positions.count <= 8 else { return [] }

        var results: [String] = []
        results.reserveCapacity(1 << positions.count)
        for mask in 0..<(1 << positions.count) {
            var line = ""
            for index in word.indices {
                if let position = positions.firstIndex(of: index) {
                    line.append((mask >> position) & 1 == 1 ? palochka : word[index])
                } else {
                    line.append(word[index])
                }
            }
            results.append(line)
        }
        return results
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

    /// Орфографическая автокоррекция чеченских опечаток (PLAN-chechen §3.3).
    ///
    /// Применяется ТОЛЬКО при всех условиях сразу:
    /// - функция включена пользователем (по умолчанию выключена);
    /// - слово кириллическое, длина ≥ 4;
    /// - слова НЕТ в чеченском словаре;
    /// - оно НЕ является допустимым русским словом (смешанный
    ///   русско-чеченский текст — норма, русские слова не трогаются);
    /// - в словаре существует РОВНО ОДИН кандидат на расстоянии одной правки,
    ///   причём сохраняющий первую букву (дополнительный предохранитель
    ///   против межъязыковых подмен);
    /// - кандидат — не имя собственное.
    @MainActor
    static func typoCorrection(for word: String) -> String? {
        // Пользовательское исключение: слово отменялось через undo.
        guard !UserWordLists.shared.isNeverCorrect(word) else { return nil }
        guard ChechenAutocorrect.isTypoCorrectionEnabled,
              ChechenLexicon.shared.isAvailable,
              word.count >= 4,
              !word.isEmpty,
              word.allSatisfy(isCyrillic),
              !ChechenLexicon.shared.contains(word),
              !isValidWord(word, language: "ru") else { return nil }

        guard let neighbor = ChechenLexicon.shared.oneEditNeighbor(of: word),
              neighbor.first == word.lowercased().first else { return nil }
        return neighbor
    }

    /// Клавиши латинской раскладки для перебора вариантов в одну правку.
    private static let latinKeys = Array("abcdefghijklmnopqrstuvwxyz[];',.")

    /// Промах по ПЕРВОЙ клавише при намерении набрать чеченское слово:
    /// существует ли замена/пропуск первой клавиши, дающая чеченское слово
    /// из словаря? Если да — ввод неоднозначен (пример: хотели "[fkj" →
    /// «хало», промахнулись → "vfkj" → «мало»), исправление пропускаем.
    @MainActor
    static func firstKeyAlternativeIsChechen(for typed: String,
                                             table: [Character: Character]) -> Bool {
        guard typed.count >= 4 else { return false }
        let base = Array(typed)
        let tail = base.dropFirst()

        func remapsToFrequentChechen(_ variant: [Character]) -> Bool {
            guard let mapped = remapped(String(variant), table: table) else { return false }
            return ChechenLexicon.shared.isFrequent(mapped)
        }

        for key in latinKeys where key != base[0] {
            var variant = [key] + tail
            if remapsToFrequentChechen(variant) { return true }
        }
        return remapsToFrequentChechen(Array(tail))
    }

    @MainActor
    private static func directCorrection(for word: String) -> (text: String, inputLanguage: String?)? {
        // ponytail: naive spellchecker + marker gate, no confidence scoring;
        // replace with the real RU/EN/Chechen classifier in Stage 5.
        if let normalized = normalizedPalochka(word) {
            return (normalized, nil)
        }

        if let table = KeyboardLayoutMap.table(from: "en", to: "ru"),
           let russian = remapped(word, table: table) {
            guard word.count >= 3,
                  !isValidWord(word, language: "en"),
                  isValidWord(russian, language: "ru") || looksChechen(russian) else { return nil }

            // Неоднозначность первого символа (PLAN-chechen §3.3): если замена
            // или пропуск ПЕРВОЙ клавиши даёт чеченское слово из словаря,
            // пользователь мог хотеть его — не исправляем вовсе. Настройка
            // включена по умолчанию; отключение возвращает агрессивный режим.
            // Пример из жизни: "vfkj" → «мало» при намерении "[fkj" → «хало».
            //
            // НО: точное попадание в словарь побеждает соседей. Если сам
            // ремап — чеченское слово ("kfhfv" → «ларам»), пользователь
            // набрал именно его; сосед по первой клавише («барам») — не
            // повод отказываться, иначе частотные слова с соседями
            // («ларам»/«барам») никогда не исправляются вовсе.
            if ChechenAutocorrect.isAmbiguityAbstentionEnabled,
               !ChechenLexicon.shared.contains(russian),
               firstKeyAlternativeIsChechen(for: word, table: table) { return nil }

            return (russian, "ru")
        }

        // Chechen typo stage (PLAN-chechen §3.3): user setting, OFF by default.
        // Runs before the Latinization guard so a marker-less misspelled
        // Chechen word can still be repaired instead of being Latinized.
        if let typo = typoCorrection(for: word) {
            return (typo, nil)
        }

        // Chechen Cyrillic words fail the Russian spellchecker — they must
        // never be "fixed" into Latin the way Punto-style switchers do.
        guard !looksChechen(word) else { return nil }

        if let table = KeyboardLayoutMap.table(from: "ru", to: "en"),
           let latin = remapped(word, table: table) {
            guard word.count >= 3,
                  !isValidWord(word, language: "ru"),
                  isValidWord(latin, language: "en") else { return nil }

            // Симметричный предохранитель: если слово отличается на одну
            // правку от известного чеченского — вероятно, это его опечатка,
            // а не английское слово; латинизировать нельзя.
            if ChechenAutocorrect.isAmbiguityAbstentionEnabled,
               ChechenLexicon.shared.hasOneEditMatch(of: word) { return nil }

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
