import Foundation

public enum DownloadError: LocalizedError {
    case badURL(String)
    case badStatus(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badURL(let url): return "Некорректный URL: \(url)"
        case .badStatus(let code, let url): return "HTTP \(code) для \(url)"
        }
    }
}

/// Загрузка источников с локальным кэшем. URL обязан содержать закреплённую
/// ревизию (хеш), иначе сборка невоспроизводима.
public enum Downloader {

    public static func fetchText(url: URL, cacheDirectory: URL) throws -> String {
        // Локальные файлы (экспортированные из parquet) читаем напрямую.
        if url.isFileURL {
            return try String(contentsOf: url, encoding: .utf8)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        let fileName = "\(Palochka.stableHash(url.absoluteString))_\(url.lastPathComponent)"
            .replacingOccurrences(of: "/", with: "_")
        let destination = cacheDirectory.appendingPathComponent(fileName)

        if fm.fileExists(atPath: destination.path) {
            return try String(contentsOf: destination, encoding: .utf8)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 180
        let semaphore = DispatchSemaphore(value: 0)
        var payload: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            payload = (data, response, error)
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = payload.2 { throw error }
        guard let data = payload.0,
              let http = payload.1 as? HTTPURLResponse, http.statusCode == 200 else {
            throw DownloadError.badStatus((payload.1 as? HTTPURLResponse)?.statusCode ?? -1,
                                          url.absoluteString)
        }
        try data.write(to: destination)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Извлечение чеченской колонки из параллельного корпуса (tsv).
    /// Русская сторона не нужна вообще — отбрасывается здесь.
    public static func extractColumn(from tsv: String, columnIndex: Int,
                                     skipHeader: Bool) -> String {
        var lines = tsv.split(separator: "\n", omittingEmptySubsequences: true)
        if skipHeader, !lines.isEmpty { lines.removeFirst() }
        var result: [Substring] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            if columnIndex < columns.count {
                result.append(columns[columnIndex])
            }
        }
        return result.joined(separator: "\n")
    }
}
