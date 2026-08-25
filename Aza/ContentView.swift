import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var hotKey: GlobalHotKey
    @ObservedObject var clipboardStore: ClipboardStore
    @ObservedObject var pasteboardMonitor: PasteboardMonitor
    @AppStorage(ChechenAutocorrect.typoStorageKey) private var typoCorrectionEnabled = false
    @AppStorage(ChechenAutocorrect.ambiguityStorageKey) private var ambiguityAbstentionEnabled = true
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @State private var pasteboardStatus = "Типы ещё не проверялись"
    @State private var pasteboardTypes = ""
    @State private var copyStatus = ""

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

            Toggle("Воздерживаться при неоднозначности с чеченским словом", isOn: $ambiguityAbstentionEnabled)
                .toggleStyle(.switch)
            Text("Включено по умолчанию: если замена или пропуск первой клавиши даёт чеченское слово — слово не трогается")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle("Собирать историю буфера", isOn: $clipboardHistoryEnabled)
                .toggleStyle(.switch)

            if clipboardHistoryEnabled {
                if clipboardStore.entries.isEmpty {
                    Text("История пуста — скопируйте что-нибудь")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clipboardStore.entries.prefix(8)) { entry in
                        Button {
                            copyToPasteboard(entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.preview(of: entry.text))
                                    .lineLimit(1)
                                Text(Self.metaLine(for: entry))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Копировать в буфер (вставьте через ⌘V)")
                    }

                    HStack {
                        Text("Всего: \(clipboardStore.entries.count) · шифрование AES-GCM включено")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Очистить") {
                            clipboardStore.clearAll()
                            copyStatus = "История очищена"
                        }
                        .font(.caption)
                    }
                }
                if !copyStatus.isEmpty {
                    Text(copyStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("История на паузе — скопированное не записывается")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
        .onAppear {
            if clipboardHistoryEnabled {
                pasteboardMonitor.start()
            }
        }
    }

    /// Копирует запись истории обратно в системный буфер.
    private func copyToPasteboard(_ entry: ClipEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        copyStatus = "Скопировано: \(Self.preview(of: entry.text)) — вставьте ⌘V"
        clipboardStore.add(
            text: entry.text,
            sourceAppBundleID: Bundle.main.bundleIdentifier,
            sourceAppName: "Aza"
        )
    }

    /// Превью для карточки: первая строка, до 48 символов.
    static func preview(of text: String) -> String {
        let firstLine = text.split(separator: "\n", maxSplits: 1)[0]
        return firstLine.count <= 48 ? String(firstLine) : firstLine.prefix(47) + "…"
    }

    /// Подпись: источник и относительное время.
    static func metaLine(for entry: ClipEntry) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let when = formatter.localizedString(for: entry.createdAt, relativeTo: Date())
        let source = entry.sourceAppName ?? (entry.sourceAppBundleID ?? "неизвестно")
        return "\(source) · \(when)"
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
    let store = ClipboardStore()
    let monitor = PasteboardMonitor(store: store)
    return ContentView(
        hotKey: GlobalHotKey(),
        clipboardStore: store,
        pasteboardMonitor: monitor
    )
}

