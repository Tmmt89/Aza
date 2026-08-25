import Foundation

/// Описание источника данных из манифеста конфигурации.
public struct SourceConfig: Codable, Hashable {
    /// Короткое имя источника: "dictionary", "quran", "bible", "news"…
    public var id: String
    /// Готовый resolve-URL с ЗАКРЕПЛЁННОЙ ревизией (хеш коммита), не ветка:
    /// https://huggingface.co/datasets/<repo>/resolve/<sha>/<file>
    public var url: String
    /// Хеш ревизии — попадает в manifest.json для воспроизводимости.
    public var revision: String
    /// Для параллельного корпуса: индекс колонки с чеченской стороной (tsv).
    /// nil — монолингвальный текст (одна колонка или сырой текст).
    public var columnIndex: Int?
    /// Пропустить первую строку (заголовок) параллельного корпуса.
    public var hasHeader: Bool
    /// Верхняя граница вклада источника в итоговые частоты (0…1).
    /// Защита от перекоса: Писания не должны задавить бытовую лексику.
    public var maxShare: Double
    /// Множитель частоты для словарных источников: заголовочное слово
    /// встречается в тексте один раз, но лексически весомее случайного
    /// вхождения. Увеличивает счётчик каждого слова источника.
    public var boost: Int?

    public init(id: String, url: String, revision: String,
                columnIndex: Int? = nil, hasHeader: Bool = false,
                maxShare: Double = 1.0, boost: Int? = nil) {
        self.id = id
        self.url = url
        self.revision = revision
        self.columnIndex = columnIndex
        self.hasHeader = hasHeader
        self.maxShare = maxShare
        self.boost = boost
    }
}

/// Одна запись готового словаря.
public struct LexiconEntry: Equatable {
    /// Нижний регистр, каноническая форма с настоящей палочкой.
    public var word: String
    /// Взвешенная частота после масштабирования источников.
    public var count: Double
    /// Встречалось ТОЛЬКО с заглавной буквы → вероятное имя собственное.
    /// Имена собственные автокоррекцией не трогаются.
    public var capitalOnly: Bool
}

/// Итоговая статистика сборки — уходит в manifest.json.
public struct BuildStats: Codable {
    public var perSourceRawTokens: [String: Int]
    public var scalingFactors: [String: Double]
    public var keptWords: Int
    public var droppedBelowMinCount: Int
    public var droppedCharset: Int
    public var minCount: Int

    init(perSourceRawTokens: [String: Int], scalingFactors: [String: Double],
         keptWords: Int, droppedBelowMinCount: Int, droppedCharset: Int, minCount: Int) {
        self.perSourceRawTokens = perSourceRawTokens
        self.scalingFactors = scalingFactors
        self.keptWords = keptWords
        self.droppedBelowMinCount = droppedBelowMinCount
        self.droppedCharset = droppedCharset
        self.minCount = minCount
    }
}

/// Накопитель частот по источникам с последующим взвешиванием.
public final class LexiconBuilder {

    private var sourcesById: [String: SourceConfig] = [:]
    /// sourceID → слово(нижний регистр, канон.) → сырая частота.
    private var perSourceCounts: [String: [String: Int]] = [:]
    private var sawLowercase = Set<String>()
    private var sawUppercase = Set<String>()

    public init() {}

    public func add(source: SourceConfig, text: String) {
        sourcesById[source.id] = source
        let tokenizer = Tokenizer()
        var bucket = perSourceCounts[source.id] ?? [:]
        for token in tokenizer.tokens(in: text) {
            let key = Normalizer.canonical(token).lowercased()
            bucket[key, default: 0] += max(1, source.boost ?? 1)
            if token.first?.isUppercase == true {
                sawUppercase.insert(key)
            } else {
                sawLowercase.insert(key)
            }
        }
        perSourceCounts[source.id] = bucket
    }

    /// Слово годится в словарь, только если состоит из кириллицы
    /// (палочка U+04C0 входит). Латиница, цифры, знаки — отбраковка.
    public static func isValidWord(_ word: String) -> Bool {
        !word.isEmpty && word.allSatisfy(Palochka.isCyrillic)
    }

    public func finalize(minCount: Int = 2) -> (entries: [LexiconEntry], stats: BuildStats) {
        // 1. Сырые суммы по источникам.
        var rawTotals: [String: Int] = [:]
        var totals: [String: Double] = [:]
        for (sid, bucket) in perSourceCounts {
            rawTotals[sid] = bucket.values.reduce(0, +)
            for (word, count) in bucket {
                totals[word, default: 0] += Double(count)
            }
        }
        let grandTotal = totals.values.reduce(0, +)

        // 2. Масштабирование источников до потолка доли.
        var factors: [String: Double] = [:]
        for (sid, cfg) in sourcesById {
            let raw = Double(rawTotals[sid] ?? 0)
            guard raw > 0, grandTotal > 0 else { continue }
            let share = raw / grandTotal
            factors[sid] = share <= cfg.maxShare ? 1.0 : (cfg.maxShare * grandTotal) / raw
        }

        // 3. Взвешенное суммирование.
        var weighted: [String: Double] = [:]
        for (sid, bucket) in perSourceCounts {
            let f = factors[sid] ?? 1.0
            for (word, count) in bucket {
                weighted[word, default: 0] += Double(count) * f
            }
        }

        // 4. Отсев мусора и сборка.
        var entries: [LexiconEntry] = []
        var low = 0, bad = 0
        for (word, count) in weighted {
            guard Self.isValidWord(word) else { bad += 1; continue }
            guard Int(count.rounded()) >= minCount else { low += 1; continue }
            entries.append(LexiconEntry(
                word: word,
                count: count,
                capitalOnly: sawUppercase.contains(word) && !sawLowercase.contains(word)
            ))
        }
        entries.sort {
            $0.count == $1.count ? $0.word < $1.word : $0.count > $1.count
        }

        let stats = BuildStats(
            perSourceRawTokens: rawTotals,
            scalingFactors: factors,
            keptWords: entries.count,
            droppedBelowMinCount: low,
            droppedCharset: bad,
            minCount: minCount
        )
        return (entries, stats)
    }
}
