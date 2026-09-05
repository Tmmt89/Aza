import AppKit
import Combine
import SwiftUI

/// Живёт в строке меню: обновления не зависят от открытия панели.
struct AzaMenuBarLabel: View {
    @ObservedObject var island: IslandStore
    @AppStorage(MenuBarDisplay.storageKey) private var display = MenuBarDisplay.logo
    @State private var now = Date.now
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let next = island.nextPrayerOccurrence(after: now)
        let description = next.map { "\($0.kind.title) \($0.time)" }
            ?? island.prayerUnavailableReason ?? "Нет ближайшего намаза"
        Group {
            if let text = display.text(for: next, now: now) {
                Text(text).monospacedDigit()
            } else {
                Image("MenuBarMark")
            }
        }
        .accessibilityLabel("Aza, \(description)")
        .help(["Aza", island.prayer.selectedCity?.name, description, next?.source?.label]
            .compactMap { $0 }.joined(separator: " · "))
        .onReceive(clock) { now = $0 }
    }
}

struct ContentView: View {
    @ObservedObject var hotKey: GlobalHotKey
    @ObservedObject var clipboardStartup: ClipboardStartup
    @ObservedObject var dictation: DictationController
    @ObservedObject var island: IslandStore
    @ObservedObject var secureInput: SecureInputMonitor
    var openSetup: () -> Void = {}
    private var clipboardStore: ClipboardStore? { clipboardStartup.store }
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @AppStorage(ChechenAutocorrect.layoutStorageKey) private var layoutCorrection = false
    @AppStorage(ChechenAutocorrect.typoStorageKey) private var typoCorrection = false
    @AppStorage(IslandStore.copyFlashKey) private var copyFlash = true
    @AppStorage(IslandStore.compactModeKey) private var islandMode = "auto"
    @AppStorage(DictationController.removeFillersStorageKey) private var removeFillers = true
    @AppStorage(DictationController.languageStorageKey) private var dictationLanguage = "auto"
    @AppStorage(MenuBarDisplay.storageKey) private var menuBarDisplay = MenuBarDisplay.logo
    @State private var showsAppearance = false
    @State private var changingNotifications = false
    @Environment(\.dismiss) private var dismiss
    /// Что сейчас мешает работать. Пусто — значит всё в порядке, и место
    /// в меню занимать нечем.
    private var warnings: [String] {
        var result: [String] = []
        if let error = hotKey.registrationError {
            result.append("Горячая клавиша недоступна (\(error))")
        }
        for (title, error) in [("Буфер", island.clipboardHotKeyError),
                               ("Фразы", island.phrasesHotKeyError),
                               ("Диктовка", dictation.hotKeyError)] {
            if let error { result.append("\(title): \(error)") }
        }
        if layoutCorrection || typoCorrection, !hotKey.inputMonitoringGranted {
            result.append("Нет мониторинга ввода — автоматическое исправление текста не работает")
        }
        if let secure = secureInput.warning {
            result.append(secure)
        }
        if let issue = island.prayer.notificationIssue {
            result.append(issue)
        }
        if let store = clipboardStore, store.isReadOnly {
            result.append(store.isUnreadable
                          ? "История на диске не читается этим ключом — она сохранена нетронутой"
                          : "Нет доступа к ключу истории — изменения не переживут перезапуск")
        }
        if let store = clipboardStore, store.lastSaveFailed {
            result.append("История не записалась на диск — последние изменения могут не пережить перезапуск")
        }
        if clipboardHistoryEnabled, clipboardStore == nil {
            result.append("История загружается…")
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    prayerCard
                    actions
                    Label(dictation.status, systemImage: dictation.state == .recording ? "mic.fill" : "mic")
                        .font(AzaStyle.caption)
                        .foregroundStyle(dictation.state == .recording ? AzaStyle.danger : AzaStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        ForEach([false, true], id: \.self) { appearanceTab in
                            Button { showsAppearance = appearanceTab } label: {
                                Text(appearanceTab ? "Оформление" : "Быстрые настройки")
                                    .font(AzaStyle.label)
                                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(MenuTileStyle(selected: showsAppearance == appearanceTab))
                            .accessibilityAddTraits(showsAppearance == appearanceTab ? .isSelected : [])
                        }
                    }
                    if showsAppearance { appearance } else { quickSettings }
                    ForEach(warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(AzaStyle.caption).foregroundStyle(AzaStyle.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .frame(height: 530)
            footer
        }
        .frame(width: 368)
        .background(AzaStyle.stage).foregroundStyle(AzaStyle.ink)
        .tint(AzaStyle.rise).preferredColorScheme(.dark)
        .onAppear { clipboardStartup.setMonitoring(enabled: clipboardHistoryEnabled) }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 30, height: 30).accessibilityHidden(true)
            Text("Aza").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                dismiss()
                island.openSetup(showing: .azaShowPrayerSettings)
            } label: {
                Label(island.prayer.selectedCity?.name ?? "Выбрать город", systemImage: "location")
                    .font(AzaStyle.caption).lineLimit(1).foregroundStyle(AzaStyle.muted)
            }
            .buttonStyle(.plain).help("Выбрать город для расписания намаза")
        }
    }

    private var prayerCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 9) {
                if let next = island.nextPrayerOccurrence(after: context.date) {
                    HStack {
                        Label("Далее · \(next.kind.title)", systemImage: next.kind.symbol)
                            .font(AzaStyle.label)
                        Spacer()
                        Text(next.source?.label ?? island.prayerSourceLabel)
                            .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(next.time)
                            .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                        Spacer()
                        Text("через \(next.countdown(from: context.date))")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(AzaStyle.rise)
                    }
                } else {
                    Label("Время намаза", systemImage: "moon.stars").font(AzaStyle.sectionTitle)
                    Text(island.prayerUnavailableReason ?? "Ближайшее время недоступно")
                        .font(AzaStyle.body).foregroundStyle(AzaStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .background(AzaStyle.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(AzaStyle.line.opacity(0.6)))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            action(dictation.state == .recording ? "Остановить" : "Диктовка",
                   symbol: dictation.state == .recording ? "stop.circle.fill" : "mic.fill", accent: true) {
                if dictation.state == .recording {
                    dictation.stopFromUI()
                } else {
                    dismiss()
                    // Возвращаем фокус в прежнее поле перед началом записи.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        dictation.startLatchedFromUI()
                    }
                }
            }
            .disabled(dictation.state != .idle && dictation.state != .recording)
            action("Буфер", symbol: "clipboard") { dismiss(); island.show(.clipboard) }
                .disabled(dictation.state != .idle)
            action("Фразы", symbol: "text.quote") { dismiss(); island.show(.phrases) }
                .disabled(dictation.state != .idle)
        }
    }

    private func action(_ title: String, symbol: String, accent: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                Text(title).font(AzaStyle.caption)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(MenuTileStyle(selected: accent))
    }

    private var quickSettings: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                quickToggle("Сохранять историю копирования", symbol: "clipboard", isOn: $clipboardHistoryEnabled,
                            help: "Сохранять новые записи в истории буфера.")
                quickToggle("Исправлять раскладку", symbol: "character.cursor.ibeam", isOn: $layoutCorrection,
                            help: "Автоматически исправлять раскладку: ghbdtn → привет.")
                quickToggle("Исправлять опечатки в чеченском", symbol: "textformat.abc", isOn: $typoCorrection,
                            help: "Автоматически исправлять опечатки в чеченских словах независимо от исправления раскладки.")
                quickToggle("Уведомлять о намазе", symbol: "bell", isOn: Binding(
                    get: { island.prayer.notificationsEnabled },
                    set: { enabled in
                        changingNotifications = true
                        Task {
                            await island.prayer.setNotifications(enabled: enabled)
                            changingNotifications = false
                        }
                    }), help: "Включить уведомления о намазе для выбранного города.")
                    .disabled(changingNotifications || island.prayer.selectedCity == nil)
                quickToggle("Индикатор копирования", symbol: "checkmark.square", isOn: $copyFlash,
                            help: "Показывать подтверждение копирования в острове.")
                quickToggle("Диктовка без слов-паразитов", symbol: "text.badge.checkmark", isOn: $removeFillers,
                            help: "Убирать слова-паразиты из результата диктовки.")
            }
            HStack {
                Label("Язык диктовки", systemImage: "globe").font(AzaStyle.body)
                Spacer()
                Picker("Язык диктовки", selection: Binding(
                    get: { DictationController.preferredLanguage },
                    set: { dictationLanguage = $0 }
                )) {
                    Text("Авто").tag("auto")
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                .labelsHidden().frame(width: 120).disabled(!dictation.canChangeSettings)
            }
        }
    }

    private func quickToggle(_ title: String, symbol: String, isOn: Binding<Bool>,
                             help: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(AzaStyle.caption)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 28, alignment: .topLeading)
            Toggle(isOn: isOn) {
                Text(isOn.wrappedValue ? "Включено" : "Выключено")
                    .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
            }
            .toggleStyle(AzaToggleStyle()).accessibilityLabel(title).accessibilityHint(help)
        }
        .padding(11)
        .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(AzaStyle.line.opacity(0.5)))
        .help(help)
    }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("В строке меню").font(AzaStyle.label).foregroundStyle(AzaStyle.muted)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let next = island.nextPrayerOccurrence(after: context.date)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(MenuBarDisplay.allCases, id: \.self) { option in
                        Button { menuBarDisplay = option } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                HStack {
                                    if let text = option.text(for: next, now: context.date) {
                                        Text(text).font(AzaStyle.label).monospacedDigit()
                                    } else {
                                        Image("MenuBarMark")
                                    }
                                    Spacer(minLength: 2)
                                    if menuBarDisplay == option {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(AzaStyle.rise)
                                    }
                                }
                                .frame(height: 18)
                                Text(option.title).font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                            }
                            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MenuTileStyle(selected: menuBarDisplay == option))
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(menuBarDisplay == option ? .isSelected : [])
                    }
                }
            }
            Text(island.prayer.selectedCity == nil
                 ? "Выберите город вверху. До этого в строке меню будет знак Aza."
                 : "Ближайшее время обновляется автоматически, в часовом поясе выбранного города.")
                .font(AzaStyle.caption).foregroundStyle(AzaStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(AzaStyle.line)
            Text("Показывать остров").font(AzaStyle.label).foregroundStyle(AzaStyle.muted)
            Picker("Показывать остров", selection: $islandMode) {
                Text("По событиям").tag("auto")
                Text("Всегда").tag("pinned")
                Text("Скрывать").tag("hidden")
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: islandMode) { _, _ in island.updateIslandPresence() }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button { dismiss(); openSetup() } label: {
                Label("Все настройки", systemImage: "gearshape")
            }
            .buttonStyle(AzaCapsuleButtonStyle())
            Spacer()
            Button {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            } label: { Image(systemName: "info.circle") }
            .accessibilityLabel("О приложении").help("О приложении")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q").accessibilityLabel("Завершить Aza").help("Завершить Aza")
        }
        .buttonStyle(.plain).font(.system(size: 14)).foregroundStyle(AzaStyle.muted)
        .padding(16)
        .overlay(alignment: .top) { AzaStyle.line.opacity(0.6).frame(height: 1) }
    }
}

private struct MenuTileStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AzaStyle.ink)
            .background(selected ? AzaStyle.rise.opacity(0.12) : AzaStyle.card,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(selected ? AzaStyle.rise.opacity(0.65) : AzaStyle.line.opacity(0.5)))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}
#Preview {
    let startup = ClipboardStartup()
    let dictation = DictationController(clipboardStore: { nil })
    return ContentView(hotKey: GlobalHotKey(), clipboardStartup: startup,
                       dictation: dictation,
                       island: IslandStore(startup: startup, dictation: dictation,
                                           prayer: PrayerStore()),
                       secureInput: SecureInputMonitor())
}
