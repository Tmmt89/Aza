import Foundation
import Combine

/// Тесты острова используют пустую историю без чтения пользовательского
/// ключа и без запуска мониторинга системного буфера из AzaApp.
@MainActor
final class ClipboardStartup: ObservableObject {
    @Published var store: ClipboardStore?
    lazy var commands = ClipboardCommands { [weak self] in self?.store }
}

func azaDebugLog(_ message: String) {}

/// В тестах нет tracking-петель AppKit — штатная проверка исполнителя.
func azaAssumeMainUnchecked<T>(_ body: @MainActor () -> T) -> T {
    MainActor.assumeIsolated(body)
}

enum TestFiles {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aza-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
