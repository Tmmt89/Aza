import CryptoKit
import Darwin
import Foundation

/// Original Meta weights, in an optional private Python runtime.
/// A worker exists only for an installation or one dictation; no listener or audio files.
@MainActor
final class OmniASR {
    nonisolated static let installationVersion = "ctc-1b-v2-python-3.12.14-1"
    nonisolated static let variantStorageKey = "OmniASRVariant"
    nonisolated static var preferredVariant: Variant {
        Variant(rawValue: UserDefaults.standard.string(forKey: variantStorageKey) ?? "ctc") ?? .ctc
    }

    enum Variant: String, CaseIterable, Identifiable {
        case ctc, llm
        var id: String { rawValue }
        var title: String { self == .ctc ? "CTC · быстрее" : "LLM · подсказка языка" }
        var modelName: String { self == .ctc ? "omniASR_CTC_1B_v2" : "omniASR_LLM_1B_v2" }
        var checkpoint: String { self == .ctc ? "omniASR-CTC-1B-v2.pt" : "omniASR-LLM-1B-v2.pt" }
        var size: Int64 { self == .ctc ? 3_902_956_068 : 9_118_733_852 }
        var sizeLabel: String { self == .ctc ? "3,9 ГБ" : "9,1 ГБ" }
        var readyFile: String { self == .ctc ? "ready" : "ready-llm-1b-v2" }
        var installationVersion: String {
            self == .ctc ? OmniASR.installationVersion : "llm-1b-v2-python-3.12.14-1"
        }
    }
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aza/OmniASR", isDirectory: true)
    }
    nonisolated static var supported: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    nonisolated static func isInstalled(_ variant: Variant = .ctc, at root: URL = directory) -> Bool {
        let manager = FileManager.default
        return (try? String(contentsOf: root.appendingPathComponent(variant.readyFile), encoding: .utf8))
            == variant.installationVersion
            && manager.isExecutableFile(atPath: root.appendingPathComponent("python/bin/python3").path)
            && ((try? manager.attributesOfItem(atPath: root.appendingPathComponent(variant.checkpoint).path)[.size]) as? NSNumber)?.int64Value == variant.size
            && ((try? manager.attributesOfItem(atPath: root.appendingPathComponent("omniASR_tokenizer_written_v2.model").path)[.size]) as? NSNumber)?.int64Value == 91_481
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Event: Decodable {
        let status: String?
        let progress: Double?
        let text: String?
        let error: String?
        let installed: Bool?
    }

    private let root: URL
    private let resources: Bundle
    private var process: Process?

    init(root: URL = OmniASR.directory, resources: Bundle = .main) {
        self.root = root
        self.resources = resources
    }

    private var python: URL { root.appendingPathComponent("python/bin/python3") }
    var isInstalled: Bool { Self.isInstalled(at: root) }
    func isInstalled(_ variant: Variant) -> Bool { Self.isInstalled(variant, at: root) }

    private func resource(_ name: String, extension suffix: String) throws -> URL {
        guard let url = resources.url(forResource: name, withExtension: suffix) else {
            throw Failure(message: "Компонент OmniASR отсутствует в приложении. Переустановите Aza.")
        }
        return url
    }

    func install(_ variant: Variant = .ctc, progress: @escaping (String, Double?) -> Void) async throws {
        guard Self.supported else { throw Failure(message: "Чеченская модель требует Apple Silicon.") }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try? manager.removeItem(at: root.appendingPathComponent(variant.readyFile))
        if !manager.isExecutableFile(atPath: python.path) {
            progress("Скачиваю компоненты чеченской модели…", nil)
            let url = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20260901/cpython-3.12.14%2B20260901-aarch64-apple-darwin-install_only.tar.gz")!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? manager.removeItem(at: temporary) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw Failure(message: "Не удалось скачать компоненты OmniASR. Повторите загрузку.")
            }
            let checksum = try await Task.detached {
                SHA256.hash(data: try Data(contentsOf: temporary)).map { String(format: "%02x", $0) }.joined()
            }.value
            guard checksum == "3ee3ee547cedfeb7c2b16b2b7156039f7b470bb8f857e226fd3d2eb11db83c76" else {
                throw Failure(message: "Контрольная сумма компонентов не совпала. Повторите загрузку.")
            }
            try Task.checkCancellation()
            // Extract into staging: a cancelled extraction must never appear usable.
            let staging = root.appendingPathComponent("runtime-download", isDirectory: true)
            if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
            try manager.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: staging) }
            _ = try await run(URL(fileURLWithPath: "/usr/bin/tar"),
                              arguments: ["-xzf", temporary.path, "-C", staging.path])
            let destination = root.appendingPathComponent("python")
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.moveItem(at: staging.appendingPathComponent("python"), to: destination)
        }
        let worker = try resource("omni-asr", extension: "py")
        let requirements = try resource("omni-requirements", extension: "txt")
        let result = try await run(python, arguments: ["-I", "-B", worker.path, "install", root.path,
                                                       requirements.path, variant.rawValue], progress: progress)
        guard result?.installed == true else { throw Failure(message: "Установка OmniASR не завершилась.") }
        try Task.checkCancellation()
        try variant.installationVersion.write(to: root.appendingPathComponent(variant.readyFile), atomically: true,
                                           encoding: .utf8)
    }

    func transcribe(_ samples: [Float], variant: Variant = .ctc,
                    progress: @escaping (String, Double?) -> Void) async throws -> String {
        guard Self.isInstalled(variant, at: root) else {
            throw Failure(message: "Сначала скачайте \(variant.modelName) в настройках диктовки.")
        }
        guard !samples.isEmpty, samples.count <= 30 * 60 * 16000,
              samples.allSatisfy(\.isFinite) else { throw Failure(message: "Некорректная запись.") }
        let worker = try resource("omni-asr", extension: "py")
        let data = samples.withUnsafeBytes { Data($0) }
        let result = try await run(python, arguments: ["-I", "-B", worker.path, "transcribe", root.path, variant.rawValue],
                                   input: data, progress: progress)
        guard let text = result?.text else { throw Failure(message: "OmniASR не вернула расшифровку.") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        process.terminate()
        // A stuck native operation still has to release audio and CPU on cancellation.
        Task { [weak process] in
            try? await Task.sleep(for: .seconds(2))
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func run(_ executable: URL, arguments: [String], input: Data? = nil,
                     progress: @escaping (String, Double?) -> Void = { _, _ in }) async throws -> Event? {
        try Task.checkCancellation()
        guard process == nil else { throw Failure(message: "OmniASR занята — дождитесь завершения.") }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = root
        // No inherited Python paths, package-index overrides or credentials.
        child.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
                             "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        let output = Pipe()
        let audio = Pipe()
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.standardInput = input == nil ? FileHandle.nullDevice : audio
        _ = fcntl(audio.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process = child
        defer {
            process = nil
            try? output.fileHandleForReading.close()
            try? audio.fileHandleForWriting.close()
        }
        return try await withTaskCancellationHandler {
            try child.run()
            let writer = Task.detached {
                defer { try? audio.fileHandleForWriting.close() }
                if let input { try audio.fileHandleForWriting.write(contentsOf: input) }
            }
            let exit = Task.detached { child.waitUntilExit(); return child.terminationStatus }
            let timeout = Task {
                try await Task.sleep(for: .seconds(30 * 60))
                if self.process === child { self.cancel() }
            }
            defer { timeout.cancel() }
            var last: Event?
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    guard let event = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { continue }
                    last = event
                    if let status = event.status { progress(status, event.progress) }
                }
            } catch {
                cancel()
                _ = await exit.value
                _ = await writer.result
                throw error
            }
            let exitCode = await exit.value
            _ = await writer.result
            try Task.checkCancellation()
            if let error = last?.error { throw Failure(message: error) }
            guard exitCode == 0 else {
                throw Failure(message: "OmniASR остановилась. Проверьте свободную память и повторите попытку.")
            }
            try await writer.value
            return last
        } onCancel: {
            Task { @MainActor in
                if self.process === child { self.cancel() }
            }
        }
    }
}
