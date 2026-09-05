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

    /// Файл есть, но не читается: личный список сохраняем как есть и
    /// больше не пишем — иначе первая же правка затрёт его пустым.
    private(set) var isUnreadable = false

    init(fileURL: URL? = nil) {
        let fileURL = fileURL ?? Self.defaultFileURL()
        self.fileURL = fileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            isUnreadable = true
            NSLog("Aza: user-words.json exists but cannot be read; keeping it untouched")
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
        LayoutCorrectionEngine.canonicalPalochkaForm(of: word)
    }

    /// Тесты движка (AzaTests) прогоняют эталонные слова; реальные
    /// пользовательские исключения (например, «[mj» после отмены) ломали
    /// бы их — на время проверки списки отключаются.
    var suspendedForTests = false

    func isNeverCorrect(_ word: String) -> Bool {
        !suspendedForTests && neverCorrect.contains(Self.storageForm(word))
    }

    func addNeverCorrect(_ word: String) {
        neverCorrect.insert(Self.storageForm(word))
        save()
    }

    /// Подтверждённые слова: пользователь принудительно исправил слово
    /// хоткеем — результат одобрен, дальше движок исправляет его сам,
    /// минуя спелчекеры и воздержания.
    func isConfirmed(_ word: String) -> Bool {
        !suspendedForTests && confirmed.contains(Self.storageForm(word))
    }

    func addConfirmed(_ word: String) {
        confirmed.insert(Self.storageForm(word))
        save()
    }

    /// Отмена исправления снимает и подтверждение — пользователь передумал.
    func removeConfirmed(_ word: String) {
        confirmed.remove(Self.storageForm(word))
        save()
    }

    func clearNeverCorrect() {
        neverCorrect.removeAll()
        save()
    }

    /// Последняя запись на диск провалилась: исключение живёт только в
    /// памяти и не переживёт перезапуск. Раньше сбой глотался молча, и
    /// статус «в исключениях» врал.
    private(set) var lastSaveFailed = false

    private func save() {
        guard !isUnreadable else {
            lastSaveFailed = true
            return
        }
        let payload = Payload(
            neverCorrect: neverCorrect.sorted(),
            confirmed: confirmed.sorted()
        )
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: fileURL, options: .atomic)
            lastSaveFailed = false
        } catch {
            lastSaveFailed = true
            NSLog("Aza: user-words save failed (%@)", error.localizedDescription)
        }
    }
}
