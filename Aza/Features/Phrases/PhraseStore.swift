import Combine
import Foundation

/// Десять фраз быстрой вставки (панель «Фразы» в острове).
///
/// Заводской список живёт в коде; файл в Application Support появляется
/// только после первого редактирования. «Сбросить до заводских» — это
/// удаление файла: никакой миграции дефолтов не нужно.
@MainActor
final class PhraseStore: ObservableObject {

    static let shared = PhraseStore()

    /// Ровно 10 слотов — по числу цифровых клавиш 1…9, 0.
    static let slotCount = 10

    static let factoryPhrases: [String] = [
        "Ассаламу Ӏалайкум | Ассаламу Ӏалайкум ва рахьматуллахӀи ва баракатухӀ",
        "Ва Ӏалайкумуссалам | Ва Ӏалайкумуссалам ва рахьматуллахӀи ва баракатухӀ",
        "АллахӀ реза хуьйла",
        "Дала везийла | Дала езийла",
        "Муха ву хьо? | Муха ю хьо?",
        "Делера маршалла хуьйла хьуна",
        "Дала аьтто бойла",
        "Дала маршалла дойла",
        "ГӀоза юург хуьйла",
        "Буьйса декъала хуьйла",
    ]

    /// Слот может держать два варианта через «|»: основной и ⇧-вариант —
    /// форма для женщины («везийла | езийла») или полное приветствие.
    /// Второго варианта нет (или он пуст) — ⇧ вставляет основной, поэтому
    /// отдельный слот под род не нужен.
    static func variant(_ raw: String, alternate: Bool) -> String {
        let (rawMain, rawAlt) = parts(raw)
        let main = rawMain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard alternate else { return main }
        let alt = rawAlt.trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? main : alt
    }

    /// Сырые половины слота для формы редактирования. Без трима: форма
    /// биндится на get/set, и трим здесь съедал бы пробел при наборе.
    static func parts(_ raw: String) -> (main: String, alt: String) {
        let split = raw.split(separator: "|", maxSplits: 1,
                              omittingEmptySubsequences: false)
        return (String(split[0]), split.count > 1 ? String(split[1]) : "")
    }

    /// Обратная сборка слота из формы; пустой ⇧-вариант «|» не оставляет.
    static func join(main: String, alt: String) -> String {
        alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? main : main + "|" + alt
    }

    @Published private(set) var phrases: [String]
    @Published private(set) var saveError: String?

    private let fileURL: URL
    /// Нечитаемый файл не удалось отложить в карантин: он всё ещё лежит на
    /// месте, и запись затёрла бы его — правки живут только в памяти.
    private var quarantineFailed = false

    /// Файл параметром — для тестов; приложение живёт через shared.
    init(fileURL: URL = PhraseStore.defaultFileURL()) {
        self.fileURL = fileURL
        // Файл с другим числом строк — от будущей/битой версии: честнее
        // показать заводские, чем панель с дырами или лишними слотами.
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String].self, from: data),
           saved.count == Self.slotCount {
            phrases = saved
        } else {
            phrases = Self.factoryPhrases
            // Файл есть, но не читается (битый или от будущей версии) —
            // откладываем в сторону, а не даём первому же редактированию
            // молча его затереть (тот же принцип, что у истории буфера).
            // Имя нумеруется: прежний карантин не перетирается.
            let manager = FileManager.default
            if manager.fileExists(atPath: fileURL.path) {
                let directory = fileURL.deletingLastPathComponent()
                var backup = directory.appendingPathComponent("phrases.unreadable.json")
                var counter = 2
                while manager.fileExists(atPath: backup.path) {
                    backup = directory.appendingPathComponent("phrases.unreadable.\(counter).json")
                    counter += 1
                }
                do {
                    try manager.moveItem(at: fileURL, to: backup)
                } catch {
                    quarantineFailed = true
                    saveError = "Файл фраз не читается и не удалось сохранить его копию. Восстановите исходные фразы или проверьте доступ к папке Aza."
                }
            }
        }
    }

    var isCustomized: Bool { phrases != Self.factoryPhrases }

    func update(_ index: Int, text: String) {
        guard phrases.indices.contains(index), phrases[index] != text else { return }
        phrases[index] = text
        save()
    }

    /// Не теряем набранный текст при отказе диска; ошибка остаётся видимой
    /// до успешной записи, которую можно повторить без нового редактирования.
    func save() {
        guard !quarantineFailed else {
            saveError = "Фразы не сохранены: прежний файл не читается. Восстановите исходные фразы или проверьте доступ к папке Aza."
            return
        }
        do {
            let data = try JSONEncoder().encode(phrases)
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Фразы не сохранены: \(error.localizedDescription)"
        }
    }

    func resetToFactory() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            quarantineFailed = false
            phrases = Self.factoryPhrases
            saveError = nil
        } catch {
            saveError = "Не удалось восстановить исходные фразы: \(error.localizedDescription)"
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aza", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("phrases.json")
    }
}
