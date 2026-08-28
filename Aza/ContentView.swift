import AppKit
import SwiftUI

/// Меню статус-бара: что сейчас происходит и быстрые паузы. Не вторые
/// настройки (всё настраиваемое — в окне настроек) и не второй буфер
/// (история живёт в острове, сюда — только кнопка перехода).
struct ContentView: View {
    @ObservedObject var hotKey: GlobalHotKey
    @ObservedObject var clipboardStartup: ClipboardStartup
    @ObservedObject var dictation: DictationController
    /// Остров держит времена намаза — панель показывает то же самое.
    @ObservedObject var island: IslandStore
    /// Открыть окно настройки (§9) — оно же страница состояния прав.
    var openSetup: () -> Void = {}
    /// Хранилище появляется после фонового получения ключа Keychain.
    private var clipboardStore: ClipboardStore? { clipboardStartup.store }
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @AppStorage(ChechenAutocorrect.layoutStorageKey) private var layoutCorrection = true
    @Environment(\.dismiss) private var dismiss

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
        if clipboardHistoryEnabled, clipboardStore == nil {
            result.append("История загружается… (возможно, Keychain ждёт ответа в диалоге)")
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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

            // Статус диктовки: в покое подсказывает сочетание, во время
            // работы — что происходит.
            Label(dictation.status, systemImage: dictation.state == .recording ? "mic.fill" : "mic")
                .font(.caption)
                .foregroundStyle(dictation.state == .recording ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Диктовка без клавиатуры: из меню запись всегда фиксированная —
            // остановят повторное нажатие сочетания, Пробел или Enter.
            if dictation.state == .recording {
                Button { dictation.stopFromUI() } label: {
                    Label("Остановить запись", systemImage: "stop.circle")
                        .font(.caption)
                }
            } else {
                Button {
                    dismiss()
                    // Пауза, чтобы фокус успел вернуться из меню в прежнее
                    // поле — иначе вставлять будет некуда и текст уйдёт
                    // только в буфер.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        dictation.startLatchedFromUI()
                    }
                } label: {
                    Label("Начать диктовку", systemImage: "mic.badge.plus")
                        .font(.caption)
                }
                // Кнопка видна всегда, но ждёт покоя: прятать её на время
                // загрузки модели — значит «кнопки нет» сразу после запуска.
                .disabled(dictation.state != .idle)
            }

            Divider()

            // Быстрые паузы — действия «на минуту», а не настройки:
            // историю выключают, когда копируют чужое, раскладку — когда
            // автозамена мешает прямо сейчас.
            Toggle("Собирать историю буфера", isOn: $clipboardHistoryEnabled)
                .toggleStyle(AzaToggleStyle())
                .font(.callout)
            Toggle("Исправлять раскладку", isOn: $layoutCorrection)
                .toggleStyle(AzaToggleStyle())
                .font(.callout)

            Button {
                dismiss()
                island.mode = .clipboard
            } label: {
                Label("История буфера…", systemImage: "clipboard")
                    .font(.caption)
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
        .frame(width: 300)
        .onAppear {
            clipboardStartup.setMonitoring(enabled: clipboardHistoryEnabled)
        }
    }
}

#Preview {
    let startup = ClipboardStartup()
    let dictation = DictationController(clipboardStore: { nil })
    return ContentView(hotKey: GlobalHotKey(), clipboardStartup: startup,
                       dictation: dictation,
                       island: IslandStore(startup: startup, dictation: dictation,
                                           prayer: PrayerStore()))
}
