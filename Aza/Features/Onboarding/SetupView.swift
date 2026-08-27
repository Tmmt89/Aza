import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Одна страница настройки (§9): что умеет функция, зачем ей разрешение,
/// что уже выдано. Ни одно разрешение не обязательно — отказ выключает
/// только свою функцию.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    @AppStorage(PrayerStore.cityStorageKey) private var cityID = ""
    @AppStorage(DictationController.profileStorageKey) private var profile = "balanced"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aza").font(.title2.weight(.semibold))
                    Text("Намаз, диктовка, раскладка и история буфера — всё локально на вашем Mac. Любой пункт можно пропустить: без разрешения не работает только его функция.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Город для намаза",
                        detail: "Времена считаются на вашем Mac. Готовое расписание ДУМ используется, если вы его добавите; иначе — астрономический расчёт.") {
                    Picker("", selection: $cityID) {
                        Text("Не выбран").tag("")
                        ForEach(PrayerStore.cities) { city in
                            Text(city.name).tag(city.id)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: cityID) { _, value in
                        model.prayer.selectedCityID = value.isEmpty ? nil : value
                    }
                }

                section("Уведомления о намазе",
                        detail: "Системное уведомление ко времени намаза или заранее.",
                        status: status(for: model.notifications)) {
                    if model.notifications == .notDetermined {
                        Button("Разрешить") { Task { await model.requestNotifications() } }
                    } else if model.notifications == .denied {
                        Text("Включить можно в Системных настройках → Уведомления")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Микрофон",
                        detail: "Нужен для диктовки. Аудио не сохраняется на диск и не покидает компьютер.",
                        status: status(for: model.microphone)) {
                    if model.microphone == .notDetermined {
                        Button("Разрешить") { model.requestMicrophone() }
                    }
                }

                section("Модель распознавания",
                        detail: "Скачивается один раз с Hugging Face. Это единственный исходящий трафик Aza.") {
                    Picker("", selection: $profile) {
                        ForEach(DictationController.Profile.allCases) { item in
                            Text(item.title).tag(item.rawValue)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: profile) { _, _ in model.dictation.profileChanged() }
                    Text(DictationController.Profile(rawValue: profile)?.summary ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }

                section("Управление компьютером (Accessibility)",
                        detail: "Позволяет вставлять текст прямо в поле — распознанный или из истории буфера. Без него текст остаётся в буфере.",
                        status: model.axTrusted ? .granted : .missing) {
                    if !model.axTrusted {
                        Button("Открыть настройки") { model.requestAccessibility() }
                        Text("Выданное разрешение подхватится, когда вы вернётесь в Aza.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("Мониторинг ввода",
                        detail: "Нужен, чтобы видеть завершённое слово и исправлять раскладку.",
                        status: model.inputMonitoring ? .granted : .missing) {
                    if !model.inputMonitoring {
                        HStack {
                            Button("Разрешить") { model.requestInputMonitoring() }
                            Button("Открыть настройки") { model.openInputMonitoringSettings() }
                        }
                        // Честно: это разрешение начинает действовать
                        // только после перезапуска процесса.
                        Text("Это разрешение вступает в силу только после перезапуска Aza.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Перезапустить Aza") { model.restartApp() }
                            .font(.caption)
                    }
                }

                section("Запуск при входе",
                        detail: "Aza будет запускаться вместе с macOS.",
                        status: model.loginItem == .enabled ? .granted : .missing) {
                    Toggle("Запускать при входе", isOn: Binding(
                        get: { model.loginItem == .enabled },
                        set: { model.setLoginItem($0) }
                    ))
                    .toggleStyle(.switch)
                    if let error = model.loginItemError {
                        Text("Не удалось: \(error)")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.loginItem == .requiresApproval {
                        Text("Подтвердите в Системных настройках → Основные → Элементы входа.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Spacer()
                    Button("Готово") {
                        UserDefaults.standard.set(true, forKey: SetupWindowController.completedKey)
                        dismiss()
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 460, minHeight: 560)
    }

    // MARK: Сборка секции

    enum Status {
        case granted, missing, unknown
    }

    private func status(for value: AVAuthorizationStatus) -> Status {
        switch value {
        case .authorized: .granted
        case .notDetermined: .unknown
        default: .missing
        }
    }

    private func status(for value: UNAuthorizationStatus) -> Status {
        switch value {
        case .authorized, .provisional: .granted
        case .notDetermined: .unknown
        default: .missing
        }
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String,
        detail: String,
        status: Status = .unknown,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                if status == .granted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if status == .missing {
                    Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                }
            }
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }
}
