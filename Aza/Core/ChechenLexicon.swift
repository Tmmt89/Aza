import Foundation

/// Частотный словарь чеченских слов, собранный конвейером
/// Tools/BuildChechenLexicon (артефакт lexicon.tsv в ресурсах бандла).
///
/// Загружается лениво при первом обращении: пока пользователь не коснулся
/// чеченского текста, память не расходуется. Если ресурс не найден
/// (словарь убрали из сборки из-за лицензии), остаётся пустым — движок
/// коррекции откатывается на поведение без словаря.
@MainActor
final class ChechenLexicon {
    static let shared = ChechenLexicon()

    /// Все слова в нижнем регистре, каноническая палочка U+04CF.
    private(set) var words: Set<String> = []
    /// Слова, встречавшиеся в корпусе ТОЛЬКО с заглавной — вероятные имена
    /// собственные; автокоррекцией не трогаются.
    private(set) var capitalOnlyWords: Set<String> = []

    private init() {
        guard let url = Bundle.main.url(forResource: "chechen-lexicon", withExtension: "tsv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        for line in content.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard let first = fields.first, !first.isEmpty else { continue }
            let word = String(first)
            words.insert(word)
            if fields.count > 2, fields[2] == "1" {
                capitalOnlyWords.insert(word)
            }
        }
    }

    /// Словарь загружен и им можно пользоваться.
    var isAvailable: Bool { !words.isEmpty }

    /// Регистронезависимая проверка: вход может содержать любую из двух
    /// кодовых точек палочки — lowercased() сводит U+04C0 к U+04CF.
    func contains(_ word: String) -> Bool {
        words.contains(word.lowercased())
    }
}
