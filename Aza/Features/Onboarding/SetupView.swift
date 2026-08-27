import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Настройка и состояние разрешений (§9) в дизайн-системе Aza.
///
/// Компактная группировка: разрешения — строками в одной карточке, а не
/// семь крупных блоков; объяснение показывается там, где от пользователя
/// ещё требуется действие, а выданное разрешение сворачивается в строку
/// со статусом.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    @AppStorage(PrayerStore.cityStorageKey) private var cityID = ""
    @AppStorage(DictationController.profileStorageKey) private var profile = "balanced"
    @StateObject private var locator = CityLocator()

    var body: some View {
        ZStack {
            AzaStyle.stage.ignoresSafeArea()

            // Две колонки вместо длинной ленты: всё умещается на экран
            // без прокрутки — настройки должны быть видны целиком.
            VStack(alignment: .leading, spacing: 12) {
                header
                HStack(alignment: .top, spacing: 12) {
                    permissionsCard
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(spacing: 12) {
                        prayerCard
                        dictationCard
                        generalCard
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                footer
            }
            .padding(18)
        }
        .frame(width: 640)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }

    // MARK: Шапка и подвал

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AzaStyle.acid)
                .frame(width: 28, height: 28)
                .background(AzaStyle.acidSurface, in: RoundedRectangle(
                    cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Aza").font(AzaStyle.title).foregroundStyle(AzaStyle.ink)
                Text("Всё локально. Любой пункт можно пропустить.")
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Готово") {
                UserDefaults.standard.set(true, forKey: SetupWindowController.completedKey)
                NSApp.keyWindow?.close()
            }
            .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Разрешения — одной группой

    private var permissionsCard: some View {
        card("Разрешения") {
            permissionRow(
                "Уведомления", symbol: "bell",
                status: status(model.notifications),
                detail: "Напоминание ко времени намаза.",
                denied: "Включается в Системных настройках → Уведомления"
            ) {
                Button("Разрешить") { Task { await model.requestNotifications() } }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
            }

            divider
            permissionRow(
                "Микрофон", symbol: "mic",
                status: status(model.microphone),
                detail: "Нужен для диктовки; аудио не сохраняется на диск.",
                denied: "Включается в Системных настройках → Микрофон"
            ) {
                Button("Разрешить") { model.requestMicrophone() }
                    .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
            }

            divider
            permissionRow(
                "Управление компьютером", symbol: "hand.tap",
                status: model.axTrusted ? .granted : .missing,
                detail: "Вставка текста прямо в поле. Без него текст остаётся в буфере."
            ) {
                Button("Открыть настройки") { model.requestAccessibility() }
                    .buttonStyle(AzaCapsuleButtonStyle())
            }

            divider
            permissionRow(
                "Мониторинг ввода", symbol: "keyboard",
                status: model.inputMonitoring ? .granted : .missing,
                detail: "Нужен для исправления раскладки. Действует после перезапуска Aza."
            ) {
                HStack(spacing: 6) {
                    Button("Разрешить") { model.requestInputMonitoring() }
                        .buttonStyle(AzaCapsuleButtonStyle(tint: AzaStyle.acid, prominent: true))
                    Button("Перезапустить") { model.restartApp() }
                        .buttonStyle(AzaCapsuleButtonStyle())
                }
            }
        }
    }

    // MARK: Остальные разделы

    private var prayerCard: some View {
        card("Намаз") {
            HStack(spacing: 8) {
                Picker("", selection: $cityID) {
                    Text("Город не выбран").tag("")
                    ForEach(PrayerStore.cities) { city in
                        Text(city.name).tag(city.id)
                    }
                }
                .labelsHidden()
                .onChange(of: cityID) { _, value in
                    model.prayer.selectedCityID = value.isEmpty ? nil : value
                }
                Button(locator.state == .locating ? "Определяю…" : "По геопозиции") {
                    Task {
                        if let match = await locator.locate() {
                            cityID = match.city.id
                            model.prayer.selectedCityID = match.city.id
                        }
                    }
                }
                .buttonStyle(AzaCapsuleButtonStyle())
                .disabled(locator.state == .locating)
            }
            switch locator.state {
            case let .found(id, distance):
                // Честно: ближайший ПРОФИЛЬ из списка, а не «ваш город».
                hint("Ближайший профиль: \(PrayerStore.cities.first { $0.id == id }?.name ?? id) · \(distance) км")
            case .denied:
                warn("Геолокация запрещена — выберите город вручную")
            case let .failed(message):
                warn(message)
            default:
                hint("Расписание ДУМ используется, если вы его добавите; иначе — расчёт.")
            }
        }
    }

    private var dictationCard: some View {
        card("Диктовка") {
            Picker("", selection: $profile) {
                ForEach(DictationController.Profile.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .labelsHidden()
            .onChange(of: profile) { _, _ in model.dictation.profileChanged() }
            hint(DictationController.Profile(rawValue: profile)?.summary ?? "")
        }
    }

    private var generalCard: some View {
        card("Общее") {
            Toggle("Запускать вместе с macOS", isOn: Binding(
                get: { model.loginItem == .enabled },
                set: { model.setLoginItem($0) }
            ))
            .toggleStyle(.switch)
            .tint(AzaStyle.acid)
            .font(AzaStyle.body)
            .foregroundStyle(AzaStyle.ink)
            if let error = model.loginItemError {
                warn("Не удалось: \(error)")
            }
            if model.loginItem == .requiresApproval {
                hint("Подтвердите в Системных настройках → Элементы входа.")
            }
        }
    }

    // MARK: Составные части

    enum Status { case granted, missing, unknown }

    private func status(_ value: AVAuthorizationStatus) -> Status {
        switch value {
        case .authorized: .granted
        case .notDetermined: .unknown
        default: .missing
        }
    }

    private func status(_ value: UNAuthorizationStatus) -> Status {
        switch value {
        case .authorized, .provisional: .granted
        case .notDetermined: .unknown
        default: .missing
        }
    }

    private var divider: some View {
        Rectangle().fill(AzaStyle.line).frame(height: 1).padding(.vertical, 1)
    }

    /// Строка разрешения: выданное сворачивается в одну строку, остальные
    /// показывают объяснение и действие — место тратится там, где нужно.
    @ViewBuilder
    private func permissionRow<Actions: View>(
        _ title: String,
        symbol: String,
        status: Status,
        detail: String,
        denied: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(status == .granted ? AzaStyle.acid : AzaStyle.muted)
                    .frame(width: 20, height: 20)
                    .background(status == .granted ? AzaStyle.acidSurface : AzaStyle.control,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Text(title).font(AzaStyle.label).foregroundStyle(AzaStyle.ink)
                Spacer()
                statusBadge(status)
            }
            if status != .granted {
                Text(detail)
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.faint)
                    .fixedSize(horizontal: false, vertical: true)
                // Отклонённое разрешение система повторно не спрашивает —
                // вместо бесполезной кнопки говорим, где его включить.
                if status == .missing, let denied {
                    hint(denied)
                } else {
                    actions()
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: Status) -> some View {
        switch status {
        case .granted:
            Text("Выдано")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.acid)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AzaStyle.acidSurface, in: Capsule())
        case .missing:
            Text("Не выдано")
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(AzaStyle.control, in: Capsule())
        case .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func card<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AzaStyle.caption)
                .foregroundStyle(AzaStyle.faint)
                .textCase(.uppercase)
                .tracking(0.7)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AzaStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AzaStyle.line))
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(AzaStyle.caption)
            .foregroundStyle(AzaStyle.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warn(_ text: String) -> some View {
        Text(text)
            .font(AzaStyle.caption)
            .foregroundStyle(AzaStyle.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}
