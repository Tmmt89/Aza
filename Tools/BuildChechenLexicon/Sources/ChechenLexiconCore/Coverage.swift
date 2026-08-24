import Foundation

public struct CoverageReport {
    public var totalTokens = 0
    public var recognized = 0
    /// Первые N неизвестных слов — для ручного разбора мусора.
    public var unknownSample: [String] = []

    public var ratio: Double {
        totalTokens == 0 ? 0 : Double(recognized) / Double(totalTokens)
    }
}

/// Замер покрытия словарём отложенной части корпуса.
///
/// GO/NO-GO: если покрытие бытового текста (новости/художественная проза,
/// НЕ Писания) ниже ~70%, словарь не готов к автокоррекции опечаток.
public enum Coverage {

    public static func measure(lexicon: Set<String>, text: String,
                               sampleLimit: Int = 30) -> CoverageReport {
        var report = CoverageReport()
        for token in Tokenizer().tokens(in: text) {
            let canonical = Normalizer.canonical(token)
            let lower = canonical.lowercased()
            report.totalTokens += 1
            if lexicon.contains(lower) || lexicon.contains(canonical) {
                report.recognized += 1
            } else if report.unknownSample.count < sampleLimit {
                report.unknownSample.append(token)
            }
        }
        return report
    }

    public static func loadLexicon(tsvPath: String) throws -> Set<String> {
        let content = try String(contentsOfFile: tsvPath, encoding: .utf8)
        var words = Set<String>()
        for line in content.split(separator: "\n") {
            if let word = line.split(separator: "\t").first {
                words.insert(String(word))
            }
        }
        return words
    }
}
