import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var hotKey: GlobalHotKey
    @ObservedObject var clipboardStartup: ClipboardStartup
    @ObservedObject var dictation: DictationController
    /// Явные подписки: команды и хранилище — отдельные ObservableObject,
    /// и без них открытая панель не перерисовывалась бы на изменение
    /// истории или окна «Отменить».
    @ObservedObject var commands: ClipboardCommands
    /// Остров держит времена намаза — панель показывает то же самое.
    @ObservedObject var island: IslandStore
    /// Открыть окно настройки (§9) — оно же страница состояния прав.
    var openSetup: () -> Void = {}
    /// Хранилище появляется после фонового получения ключа Keychain.
    private var clipboardStore: ClipboardStore? { clipboardStartup.store }
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @State private var searchText = ""
    @State private var visibleLimit = 10
    @State private var confirmMassDelete = false
    /// Запись, открытая в popover «Показать целиком».
    @State private var previewEntry: ClipEntry?

    /// Что сейчас мешает работать. Пусто — значит всё в порядке, и место
    /// в меню занимать нечем.
    private var warnings: [String] {
        var result: [String] = []
        if let error = hotKey.registrationError {
            result.append("Горячая клавиша недоступна (\(error))")
        }
        if !hotKey.inputMonitoringGranted {
            result.append("Нет мониторинга ввода — исправление раскладки не работает")
        }
        if let issue = island.prayer.notificationIssue {
            result.append(issue)
        }
        if let store = clipboardStore, store.isReadOnly {
            result.append(store.isUnreadable
                          ? "История на диске не читается этим ключом — она сохранена нетронутой"
                          : "Нет доступа к ключу истории — изменения не переживут перезапуск")
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Меню — не вторые настройки. Здесь только то, ради чего его
            // открывают: что сейчас происходит и история буфера. Всё
            // настраиваемое живёт в окне настроек, и дублировать его
            // значит заставлять пользователя гадать, где менять.
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .foregroundStyle(.tint)
                Text("Aza")
                    .font(.headline)
                Spacer()
                Text(island.prayerSourceLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            // Ближайший намаз — главное, за чем сюда заглядывают.
            if let next = island.nextPrayerOccurrence() {
                HStack(spacing: 6) {
                    Image(systemName: next.kind.symbol)
                        .font(.caption)
                        .foregroundStyle(.tint)
                    Text("\(next.kind.title) в \(next.time)")
                        .font(.callout)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(next.countdown(from: context.date))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let reason = island.prayerUnavailableReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(island.prayer.selectedCity == nil
                                     ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Предупреждения показываются, только когда есть что чинить:
            // исправная работа не должна занимать место.
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if dictation.state != .idle {
                Label(dictation.status, systemImage: dictation.state == .recording ? "mic.fill" : "mic")
                    .font(.caption)
                    .foregroundStyle(dictation.state == .recording ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Пауза — действие, а не настройка: её включают на минуту,
            // когда копируют чужое. Место ей здесь, а срок хранения — в
            // настройках.
            Toggle("Собирать историю буфера", isOn: $clipboardHistoryEnabled)
                .toggleStyle(.switch)
                .font(.caption)

            if clipboardHistoryEnabled, clipboardStore == nil {
                // Ключ Keychain добывается на фоне — возможно, ждёт ответа
                // в диалоге (разблокировка связки). Приложение не блокируется.
                Label("История загружается… (возможно, Keychain ждёт ответа в диалоге)",
                      systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if clipboardHistoryEnabled, let clipboardStore {
                TextField("Поиск по истории", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                let visibleEntries = ClipboardCommands.filtered(
                    entries: clipboardStore.entries, query: searchText
                )

                if visibleEntries.isEmpty {
                    Text(searchText.isEmpty ? "История пуста — скопируйте что-нибудь" : "Ничего не найдено")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visibleEntries.prefix(visibleLimit)) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Button {
                                commands.insertIntoActiveApp(entry)
                            } label: {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Вставить в активное поле предыдущего приложения")

                            Button {
                                commands.copyToPasteboard(entry)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        if let thumb = entry.thumbnailData,
                                           let image = NSImage(data: thumb) {
                                            Image(nsImage: image)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(maxWidth: 36, maxHeight: 24)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        } else if let icon = Self.kindIcon(for: entry) {
                                            Image(systemName: icon)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(Self.preview(of: entry.text))
                                            .lineLimit(1)
                                            .foregroundStyle(.primary)
                                    }
                                    Text(Self.metaLine(for: entry))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Клик — копировать в буфер; вставьте ⌘V")

                            Spacer()

                            Button {
                                clipboardStore.toggleFavorite(id: entry.id)
                            } label: {
                                Image(systemName: entry.isFavorite == true
                                      ? "star.fill" : "star")
                                    .foregroundStyle(entry.isFavorite == true
                                                     ? .yellow : .secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Избранное — не удаляется автоочисткой")
                        }
                        .contextMenu {
                            Button("Показать целиком") {
                                previewEntry = entry
                            }
                            Button("Удалить", role: .destructive) {
                                commands.delete(entry)
                            }
                        }
                        .popover(isPresented: Binding(
                            get: { previewEntry?.id == entry.id },
                            set: { if !$0 { previewEntry = nil } }
                        )) {
                            entryPreview(entry)
                        }
                    }

                    if visibleEntries.count > visibleLimit {
                        Button("Показать ещё (\(visibleEntries.count - visibleLimit))") {
                            visibleLimit += 10
                        }
                        .font(.caption)
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Text(Self.footerLine(entries: clipboardStore.entries,
                                             shown: min(visibleEntries.count, visibleLimit)))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !searchText.isEmpty {
                            let deletable = visibleEntries.filter { $0.isFavorite != true }
                            if !deletable.isEmpty {
                                if confirmMassDelete {
                                    Button("Точно удалить \(deletable.count)?", role: .destructive) {
                                        commands.deleteAll(visibleEntries)
                                    }
                                    .font(.caption)
                                    Button("Нет") { confirmMassDelete = false }
                                        .font(.caption)
                                } else {
                                    Button("Удалить найденное (\(deletable.count))") {
                                        confirmMassDelete = true
                                    }
                                    .font(.caption)
                                }
                            }
                            Button("Сбросить поиск") { searchText = "" }
                                .font(.caption)
                        }
                        Button("Очистить") { commands.clearAll() }
                        .font(.caption)
                    }
                }
                // Вне ветки списка: «Отменить» доступна и когда удалили
                // последнюю видимую карточку (список/поиск пуст).
                if !commands.pendingUndo.isEmpty {
                    HStack(spacing: 6) {
                        Text(commands.pendingUndo.count == 1
                             ? "Удалено: \(Self.preview(of: commands.pendingUndo[0].entry.text))"
                             : "Удалено записей: \(commands.pendingUndo.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Отменить") { commands.undo() }
                            .font(.caption)
                    }
                }
                if !commands.status.isEmpty {
                    Text(commands.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("История на паузе — скопированное не записывается")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("Настройки…") { openSetup() }
                    .font(.caption)
                Spacer()
                Button("Завершить") { NSApp.terminate(nil) }
                    .font(.caption)
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            clipboardStartup.setMonitoring(enabled: clipboardHistoryEnabled)
        }
        .onChange(of: searchText) { _, _ in
            confirmMassDelete = false
        }
    }






    static func footerLine(entries: [ClipEntry], shown: Int) -> String {
        let favorites = entries.filter { $0.isFavorite == true }.count
        return "Всего \(entries.count), показано \(shown)" +
            (favorites > 0 ? " · в избранном \(favorites)" : "") +
            " · шифрование AES-GCM"
    }


    /// Полный просмотр записи. Настоящий Quick Look не используется
    /// сознательно: QLPreviewPanel требует файл на диске, а расшифрованное
    /// содержимое не должно попадать на диск открытым текстом.
    @ViewBuilder
    private func entryPreview(_ entry: ClipEntry) -> some View {
        ScrollView {
            if entry.resolvedKind == .image {
                if let data = clipboardStore?.imageData(for: entry),
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("Изображение недоступно")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(entry.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 360, minHeight: 80, maxHeight: 420)
    }

    /// Иконка вида записи; текст без иконки — карточек-текстов большинство.
    static func kindIcon(for entry: ClipEntry) -> String? {
        switch entry.resolvedKind {
        case .text: return nil
        case .rtf: return "doc.richtext"
        case .image: return "photo"
        case .files: return "doc.on.doc"
        case .link: return "link"
        }
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

}

#Preview {
    let startup = ClipboardStartup()
    let dictation = DictationController(clipboardStore: { nil })
    return ContentView(hotKey: GlobalHotKey(), clipboardStartup: startup,
                       dictation: dictation, commands: startup.commands,
                       island: IslandStore(startup: startup, dictation: dictation,
                                           prayer: PrayerStore()))
}
