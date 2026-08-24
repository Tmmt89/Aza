import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var hotKey: GlobalHotKey
    @State private var pasteboardStatus = "Типы ещё не проверялись"
    @State private var pasteboardTypes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Aza работает локально", systemImage: "waveform")
                .font(.headline)

            if let error = hotKey.registrationError {
                Label("Горячая клавиша недоступна (\(error))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else {
                Text("Поставьте курсор в текстовое поле и нажмите ⌘⇧A")
                    .lineLimit(2)
                Text(hotKey.insertionStatus)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("Срабатываний: \(hotKey.activationCount)")
                    .foregroundStyle(.secondary)
            }

            Divider()

            if hotKey.inputMonitoringGranted {
                Text("В TextEdit: ghbdtn + пробел")
                Text("\(hotKey.correctionStatus) · исправлений: \(hotKey.correctionCount)")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Button("Разрешить Input Monitoring") {
                    hotKey.requestInputMonitoring()
                }
                Text("Нужно для анализа завершённого слова")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Прочитать типы буфера") {
                inspectPasteboard()
            }
            Text(pasteboardStatus)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !pasteboardTypes.isEmpty {
                Text(pasteboardTypes)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }

            Divider()

            Button("Завершить Aza") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 280)
    }

    private func inspectPasteboard() {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let types = Set(items.flatMap(\.types))
#if DEBUG
        assert(Self.categories(for: [.string]) == ["текст"])
#endif
        let excluded = types.contains {
            $0.rawValue == "org.nspasteboard.ConcealedType" ||
            $0.rawValue == "org.nspasteboard.TransientType"
        }
        if excluded {
            pasteboardTypes = ""
            pasteboardStatus = "Исключено: confidential/transient"
        } else if items.isEmpty {
            pasteboardTypes = ""
            pasteboardStatus = "Буфер пуст"
        } else {
            pasteboardTypes = types.map(\.rawValue).sorted().joined(separator: "\n")
            let categories = Self.categories(for: types)
            pasteboardStatus = "\(items.count) объект(а): " +
                (categories.isEmpty ? "неизвестный тип" : categories.joined(separator: ", "))
        }
    }

    private static func categories(for types: Set<NSPasteboard.PasteboardType>) -> [String] {
        var result: [String] = []
        if types.contains(.string) { result.append("текст") }
        if !types.isDisjoint(with: [.rtf, .rtfd, .html]) { result.append("форматированный текст") }
        if types.contains(.URL) { result.append("ссылка") }
        if !types.isDisjoint(with: [.png, .tiff]) { result.append("изображение") }
        if types.contains(.fileURL) { result.append("файл/папка") }
        return result
    }
}

#Preview {
    ContentView(hotKey: GlobalHotKey())
}
