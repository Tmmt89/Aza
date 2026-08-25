import Foundation

/// Пользовательские списки слов (PLAN-chechen §8):
/// - «никогда не исправлять» — после отмены исправления;
/// - подтверждённые слова — постепенно чинят проблему покрытия.
///
/// Хранятся JSON-ом в Application Support/Aza отдельно от базы буфера
/// (другой жизненный цикл), но при «удалить все данные» чистятся вместе.
@MainActor
final class UserWordLists {

    static let shared = UserWordLists()

    private(set) var neverCorrect: Set<String> = []
    private(set) var confirmed: Set<String> = []

    private let fileURL: URL

    private struct Payload: Codable {
        var neverCorrect: [String] = []
        var confirmed: [String] = []
    }

    private init() {
        fileURL = Self.defaultFileURL()
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return
        }
        neverCorrect = Set(payload.neverCorrect.map(Self.storageForm))
        confirmed = Set(payload.confirmed.map(Self.storageForm))
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aza", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("user-words.json")
    }

    /// Форма хранения: нижний регистр + каноническая палочка, чтобы
    /// «Г1ала», «г1ала», «гІала» и «гӏала» считались одним словом.
    static func storageForm(_ word: String) -> String {
        LayoutCorrectionEngine.canonicalPalochkaForm(of: word.lowercased())
    }

    func isNeverCorrect(_ word: String) -> Bool {
        neverCorrect.contains(Self.storageForm(word))
    }

    func addNeverCorrect(_ word: String) {
        neverCorrect.insert(Self.storageForm(word))
        save()
    }

    func clearNeverCorrect() {
        neverCorrect.removeAll()
        save()
    }

    private func save() {
        let payload = Payload(
            neverCorrect: neverCorrect.sorted(),
            confirmed: confirmed.sorted()
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
