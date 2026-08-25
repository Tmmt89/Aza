import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var hotKey: GlobalHotKey
    @AppStorage(ChechenAutocorrect.storageKey) private var typoCorrectionEnabled = false
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
                    .fixedSize(horizontal: false, vertical: true)
                Text(hotKey.insertionStatus)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Срабатываний: \(hotKey.activationCount)")
                    .foregroundStyle(.secondary)
            }

            Divider()

            if hotKey.inputMonitoringGranted {
                Text("В TextEdit: ghbdtn · руддщ · [mj · 1алам + пробел")
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(hotKey.correctionStatus) · исправлений: \(hotKey.correctionCount)")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Разрешить Input Monitoring") {
                    hotKey.requestInputMonitoring()
                }
                Text("Нужно для анализа завершённого слова")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Исправлять чеченские опечатки", isOn: $typoCorrectionEnabled)
                .toggleStyle(.switch)
            Text("Выключено по умолчанию: исправляет слово, только если в словаре ровно один кандидат на расстоянии одной правки")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Button("Прочитать типы буфера") {
                inspectPasteboard()
            }
            Text(pasteboardStatus)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !pasteboardTypes.isEmpty {
                Text(pasteboardTypes)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }

            Divider()

            Text("Двойной правый Shift — отменить последнее исправление (слово попадёт в исключения)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Исключений: \(UserWordLists.shared.neverCorrect.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !UserWordLists.shared.neverCorrect.isEmpty {
                    Button("Очистить") {
                        UserWordLists.shared.clearNeverCorrect()
                    }
                    .font(.caption)
                }
            }

            Divider()

            Button("Завершить Aza") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(16)
        .frame(width: 340)
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
