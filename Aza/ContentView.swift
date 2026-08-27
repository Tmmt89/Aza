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
    @AppStorage(PrayerStore.cityStorageKey) private var prayerCityID = ""
    @StateObject private var locator = CityLocator()
    /// Хранилище появляется после фонового получения ключа Keychain.
    private var clipboardStore: ClipboardStore? { clipboardStartup.store }
    @AppStorage(ChechenAutocorrect.typoStorageKey) private var typoCorrectionEnabled = false
    @AppStorage(ChechenAutocorrect.ambiguityStorageKey) private var ambiguityAbstentionEnabled = true
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @AppStorage(ClipboardStore.retentionKey) private var retentionDays = 30
    @AppStorage(DictationController.languageStorageKey) private var dictationLanguage = "auto"
    @State private var pasteboardStatus = "Типы ещё не проверялись"
    @State private var pasteboardTypes = ""
    @State private var searchText = ""
    @State private var visibleLimit = 10
    @State private var confirmMassDelete = false
    @State private var excludedApps = UserDefaults.standard
        .stringArray(forKey: ExcludedApps.userDefaultsKey) ?? []
    @State private var newExcludedApp = ""
    /// Запись, открытая в popover «Показать целиком».
    @State private var previewEntry: ClipEntry?

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
                Text("Везде, кроме терминалов, IDE и менеджеров паролей: ghbdtn · руддщ · [mj · 1алам + пробел")
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

            // Намаз (§4): город выбирается вручную, источник называется
            // честно — таблица ДУМ, если она есть, иначе расчёт.
            Picker("Город", selection: $prayerCityID) {
                Text("Не выбран").tag("")
                ForEach(PrayerStore.cities) { city in
                    Text(city.name).tag(city.id)
                }
            }
            .pickerStyle(.menu)
            .font(.caption)
            .onChange(of: prayerCityID) { _, newValue in
                island.prayer.selectedCityID = newValue.isEmpty ? nil : newValue
            }

            HStack {
                Button(locator.state == .locating ? "Определяю…" : "Определить город") {
                    Task {
                        if let match = await locator.locate() {
                            prayerCityID = match.city.id
                            island.prayer.selectedCityID = match.city.id
                        }
                    }
                }
                .font(.caption)
                .disabled(locator.state == .locating)
                Spacer()
                Toggle("Уведомления", isOn: Binding(
                    get: { island.prayer.notificationsEnabled },
                    set: { enabled in
                        Task { await island.prayer.setNotifications(enabled: enabled) }
                    }
                ))
                .toggleStyle(.switch)
                .font(.caption)
            }
            switch locator.state {
            case .locating:
                Text("Определяю…").font(.caption2).foregroundStyle(.secondary)
            case let .found(cityID, distance):
                // Честно: это ближайший ПРОФИЛЬ из списка, а не «ваш город».
                Text("Ближайший профиль: \(PrayerStore.cities.first { $0.id == cityID }?.name ?? cityID) · \(distance) км")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .denied:
                Text("Геолокация запрещена — выберите город вручную")
                    .font(.caption2).foregroundStyle(.orange)
            case let .failed(message):
                Text(message).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }

            if let next = island.nextPrayerOccurrence() {
                Text("\(next.kind.title) в \(next.time) · \(island.prayerSourceLabel(for: next))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let caveat = next.source?.caveat {
                    Text(caveat)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Выберите город, чтобы видеть время намаза")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Диктовка (§5): удержание ⌃⇧D. Модель качается при первом
            // использовании, поэтому статус живёт отдельной строкой.
            Label(dictation.status, systemImage: dictation.state == .recording
                  ? "mic.fill" : "mic")
                .font(.caption)
                .foregroundStyle(dictation.state == .recording ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Язык диктовки", selection: $dictationLanguage) {
                Text("Авто").tag("auto")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .pickerStyle(.segmented)
            .font(.caption)
            Text("Авто: при сомнении выбирается русский")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
                Picker("Хранить", selection: $retentionDays) {
                    Text("День").tag(1)
                    Text("Неделю").tag(7)
                    Text("Месяц").tag(30)
                    Text("Год").tag(365)
                    Text("Бессрочно").tag(0)
                }
                .pickerStyle(.menu)
                .font(.caption)
            }

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
                if clipboardStore.isReadOnly {
                    Label("Нет доступа к ключу истории (Keychain) — изменения не сохранятся до перезапуска",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

            // Исключения приложений (спец. §8.9): ни коррекции, ни истории.
            Text("Приложения-исключения (bundle ID)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(excludedApps, id: \.self) { bundleID in
                HStack {
                    Text(bundleID)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Button {
                        excludedApps.removeAll { $0 == bundleID }
                        saveExcludedApps()
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("com.example.app", text: $newExcludedApp)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                Button("Добавить") {
                    let trimmed = newExcludedApp.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, !excludedApps.contains(trimmed) else { return }
                    excludedApps.append(trimmed)
                    newExcludedApp = ""
                    saveExcludedApps()
                }
                .font(.caption)
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

    private func saveExcludedApps() {
        UserDefaults.standard.set(excludedApps, forKey: ExcludedApps.userDefaultsKey)
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

    private func inspectPasteboard() {
        let items = NSPasteboard.general.pasteboardItems ?? []
        let types = Set(items.flatMap(\.types))
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
            let categories = PasteboardCategories.labels(for: types)
            pasteboardStatus = "\(items.count) объект(а): " +
                (categories.isEmpty ? "неизвестный тип" : categories.joined(separator: ", "))
        }
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
