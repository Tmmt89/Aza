import Foundation
import ChechenLexiconCore

// Конвейер сборки чеченского лексикона для Aza.
// Офлайн-инструмент, в приложение не входит; артефакт (lexicon.tsv +
// manifest.json) коммитится как готовый ресурс.

func usage() -> Never {
    print("""
    Использование:
      BuildChechenLexicon build --config <config.json> --out <dir>
      BuildChechenLexicon coverage --lexicon <dir>/lexicon.tsv --eval <file> [<file> …]

    GO/NO-GO: покрытие бытового текста (не Писания) должно быть ≥ 70%.
    """)
    exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { usage() }

let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".cache", isDirectory: true)
    .appendingPathComponent("AzaChechenLexicon", isDirectory: true)

struct ConfigFile: Codable {
    var minCount: Int
    var sources: [SourceConfig]
    /// Файл со списком русских слов (по одному в строке): все совпадения
    /// исключаются из итогового чеченского словаря.
    var russianFilterPath: String?
    /// Слово из русского фильтра всё же остаётся, если его взвешенная
    /// частота в чеченском корпусе не ниже порога (спасает ду/ху/со/вай,
    /// случайно совпавшие со строками русского списка). nil — старое
    /// безусловное исключение.
    var russianKeepMinCount: Int?
}

struct Manifest: Codable {
    var toolVersion: String
    var builtAtISO8601: String
    var minCount: Int
    var datasetRevisions: [String: String]
    var stats: BuildStats
}

/// Загружает файл фильтра русских слов (по одному слову в строке).
func loadRussianFilter(_ path: String?) -> Set<String> {
    guard let path else { return [] }
    do {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let words = Set(content.split(separator: "\n").map(String.init))
        print("→ Фильтр русских слов:", words.count, "слов из", path)
        return words
    } catch {
        print("⚠️ Не удалось загрузить фильтр русских слов:", error.localizedDescription)
        return []
    }
}

switch arguments[1] {

case "selftest":
    // Диагностика расхождений тестов и рантайма: печатает фактическое
    // содержимое таблицы подмен и результат канонизации в hex-скалярах.
    let probe = "т\u{0456}е"
    print("substitutions:", Palochka.substitutions.sorted().map {
        "U+" + String(String($0.unicodeScalars.first!.value, radix: 16)).uppercased()
    })
    print("isSubstitution(U+0456):", Palochka.isSubstitution("\u{0456}"))
    print("character:", "U+" + String(String(Palochka.character.unicodeScalars.first!.value, radix: 16)).uppercased())
    let canonized = Normalizer.canonical(probe)
    print("canonical(т+U+0456+е) скаляры:",
          canonized.unicodeScalars.map { "U+" + String($0.value, radix: 16).uppercased() })

case "build":
    guard arguments.count >= 6 else { usage() }
    var configPath: String?
    var outputDir: String?
    var i = 2
    while i + 1 < arguments.count {
        switch arguments[i] {
        case "--config": configPath = arguments[i + 1]
        case "--out": outputDir = arguments[i + 1]
        default: break
        }
        i += 2
    }
    guard let configPath, let outputDir else { usage() }

    let configData = try Data(contentsOf: URL(fileURLWithPath: configPath))
    let config = try JSONDecoder().decode(ConfigFile.self, from: configData)

    let builder = LexiconBuilder()
    var revisions: [String: String] = [:]
    for source in config.sources {
        print("→ Загрузка \(source.id) [ревизия \(source.revision)]")
        let url: URL
        if source.url.hasPrefix("http") {
            guard let parsed = URL(string: source.url) else {
                throw DownloadError.badURL(source.url)
            }
            url = parsed
        } else {
            // Локальный путь: абсолютный или относительно текущей папки.
            let basePath = source.url.hasPrefix("/")
                ? source.url
                : FileManager.default.currentDirectoryPath + "/" + source.url
            guard FileManager.default.fileExists(atPath: basePath) else {
                throw DownloadError.badStatus(404, "локальный файл не найден: \(basePath)")
            }
            url = URL(fileURLWithPath: basePath)
        }
        let raw = try Downloader.fetchText(url: url, cacheDirectory: cacheDirectory)
        let text: String
        if let column = source.columnIndex {
            text = Downloader.extractColumn(from: raw, columnIndex: column,
                                            skipHeader: source.hasHeader)
        } else {
            text = raw
        }
        builder.add(source: source, text: text)
        revisions[source.id] = source.revision
        print("   загружено \(text.split(separator: "\n").count) строк(и)")
    }

    let (entries, stats) = builder.finalize(
        minCount: config.minCount,
        excludingRussian: loadRussianFilter(config.russianFilterPath),
        russianKeepMinCount: config.russianKeepMinCount
    )
    try FileManager.default.createDirectory(atPath: outputDir,
                                            withIntermediateDirectories: true)

    // Артефакт №1: словарь — слово \t частота \t флаг «только с заглавной».
    let tsv = entries
        .map { "\($0.word)\t\(Int($0.count))\t\($0.capitalOnly ? 1 : 0)" }
        .joined(separator: "\n")
    try tsv.write(toFile: outputDir.appending("/lexicon.tsv"),
                  atomically: true, encoding: .utf8)

    // Артефакт №2: манифест воспроизводимости.
    let manifest = Manifest(
        toolVersion: "1.0",
        builtAtISO8601: ISO8601DateFormatter().string(from: Date()),
        minCount: config.minCount,
        datasetRevisions: revisions,
        stats: stats
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(manifest)
    try manifestData.write(to: URL(fileURLWithPath: outputDir.appending("/manifest.json")))

    print("""
    ✔ Готово: \(entries.count) слов → \(outputDir)/lexicon.tsv
      Отброшено: ниже порога \(stats.droppedBelowMinCount), не-кириллица \(stats.droppedCharset)
      Коэффициенты источников: \(stats.scalingFactors)
      Манифест: \(outputDir)/manifest.json

    Следующий шаг — точка go/no-go:
      BuildChechenLexicon coverage --lexicon \(outputDir)/lexicon.tsv --eval <бытовой_текст.txt>
    """)

case "coverage":
    guard arguments.count >= 5 else { usage() }
    var lexiconPath: String?
    var evalFiles: [String] = []
    var i = 2
    while i < arguments.count {
        switch arguments[i] {
        case "--lexicon": lexiconPath = arguments[i + 1]; i += 2
        case "--eval": evalFiles.append(arguments[i + 1]); i += 2
        default: i += 1
        }
    }
    guard let lexiconPath, !evalFiles.isEmpty else { usage() }

    let lexicon = try Coverage.loadLexicon(tsvPath: lexiconPath)
    print("Словарь: \(lexicon.count) слов. Порог go/no-go: ≥ 70%.")
    for file in evalFiles {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let report = Coverage.measure(lexicon: lexicon, text: text)
        let percent = ((report.ratio * 100) * 10).rounded() / 10
        print("""
        — \(file): узнано \(report.recognized)/\(report.totalTokens) (\(percent)%)
          Примеры неизвестных: \(report.unknownSample.prefix(10).joined(separator: ", "))
        """)
    }

default:
    usage()
}
