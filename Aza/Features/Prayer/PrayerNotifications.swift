import AVFoundation
import Combine
import Foundation
import UserNotifications

/// Уведомления о намазе (§4.4).
///
/// Звуки поставляются с приложением: четыре азана и три коротких
/// синтезированных сигнала (см. docs/PLAN-prayer-schedules.md). Все
/// укладываются в системный предел уведомления в 30 секунд, поэтому
/// звучат целиком.
@MainActor
final class PrayerNotifications: NSObject, UNUserNotificationCenterDelegate {

    override init() {
        super.init()
        // Без делегата macOS МОЛЧА прячет баннер и звук, когда Aza —
        // активное приложение (панель буфера держит ключевое окно):
        // уведомление уходит в Центр, а намаз проходит беззвучно.
        center.delegate = self
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// Чем звучит уведомление. Отделено от режима: «когда сработает» и
    /// «что прозвучит» — разные вопросы, и складывать их в один
    /// перечислитель значит плодить его комбинациями.
    enum Sound: String, CaseIterable {
        case system
        case adhan1
        case adhan2
        case adhan3
        case adhan4
        case chime
        case twoTone
        case warm

        var title: String {
            switch self {
            case .system: "Системный"
            case .adhan1: "Азан 1"
            case .adhan2: "Азан 2"
            case .adhan3: "Азан 3"
            case .adhan4: "Азан 4"
            case .chime: "Колокольчик"
            case .twoTone: "Две ноты"
            case .warm: "Тёплый тон"
            }
        }

        /// Имя файла в бандле; nil — играет системный звук.
        var fileName: String? {
            switch self {
            case .system: nil
            case .adhan1: "adhan-1.caf"
            case .adhan2: "adhan-2.caf"
            case .adhan3: "adhan-3.caf"
            case .adhan4: "adhan-4.caf"
            case .chime: "tone-chime.caf"
            case .twoTone: "tone-twotone.caf"
            case .warm: "tone-warm.caf"
            }
        }

        var isAdhan: Bool {
            switch self {
            case .adhan1, .adhan2, .adhan3, .adhan4: true
            default: false
            }
        }
    }

    static let soundStorageKey = "PrayerNotificationSound"

    static var sound: Sound {
        guard let raw = UserDefaults.standard.string(forKey: soundStorageKey),
              let value = Sound(rawValue: raw) else { return .system }
        return value
    }

    static func setSound(_ value: Sound) {
        UserDefaults.standard.set(value.rawValue, forKey: soundStorageKey)
    }

    enum Mode: String, CaseIterable {
        case off
        case notification
        case reminder

        var title: String {
            switch self {
            case .off: "Выключено"
            case .notification: "Уведомление"
            case .reminder: "Напоминание заранее"
            }
        }
    }

    /// Отдельный ключ на намаз: настройки независимы, атомарность не
    /// нужна, а добавление новых режимов не потребует миграции формата.
    static func modeKey(for kind: PrayerKind) -> String {
        "PrayerNotificationMode.\(kind.rawValue)"
    }
    static let reminderMinutesKey = "PrayerReminderMinutes"

    static func mode(for kind: PrayerKind) -> Mode {
        // Восход — не намаз, по умолчанию молчит.
        let fallback: Mode = kind == .sunrise ? .off : .notification
        guard let raw = UserDefaults.standard.string(forKey: modeKey(for: kind)),
              let mode = Mode(rawValue: raw) else { return fallback }
        return mode
    }

    /// Хотя бы один намаз реально уведомляется. Когда всё выключено,
    /// пустой план — норма, а не «расписание неполное».
    static var anyModeEnabled: Bool {
        PrayerKind.allCases.contains { mode(for: $0) != .off }
    }

    static var reminderMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: reminderMinutesKey)
        return stored > 0 ? stored : 10
    }

    /// Горизонт планирования: неделя. Меньше — и уведомления пропадут,
    /// если Aza несколько дней не запускалась.
    static let horizonDays = 7

    private let center = UNUserNotificationCenter.current()

    /// Разрешение спрашиваем только по явному включению (§9: ни одно
    /// разрешение не обязательно).
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Текущий статус разрешения: center.add() принимает запросы и без
    /// него, и в момент намаза система молча их выбрасывает — расписание
    /// «стоит», а звука нет. Проверяется после каждого планирования.
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        azaDebugLog("Aza: notif settings auth=\(settings.authorizationStatus.rawValue) "
            + "alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) "
            + "style=\(settings.alertStyle.rawValue)")
        return settings.authorizationStatus
    }

    /// Пересобирает расписание уведомлений: сначала добавляет нужные
    /// (одинаковый идентификатор ЗАМЕНЯЕТ запись, а не дублирует), затем
    /// снимает устаревшие. Обратный порядок — «снять всё, потом added» —
    /// оставлял бы окно, в котором ближайшее уведомление уже снято, но
    /// ещё не поставлено.
    /// Итог планирования — чтобы интерфейс мог честно сказать, что
    /// расписание неполное. На уведомления о намазе полагаются каждый
    /// день, поэтому молчаливый сбой недопустим.
    struct Outcome {
        let scheduled: Int
        let failed: Int
        var isComplete: Bool { failed == 0 }
    }

    @discardableResult
    func reschedule(days: [(date: Date, times: DayPrayerTimes)],
                    city: PrayerCity,
                    now: Date = .now) async -> Outcome {
        var wanted: Set<String> = []
        /// Id, которые ХОТЕЛИ поставить, но add упал: их прежние версии в
        /// очереди трогать нельзя — старое уведомление лучше пропавшего.
        var failedIDs: Set<String> = []
        var failed = 0

        for day in days {
            for occurrence in day.times.occurrences {
                let mode = Self.mode(for: occurrence.kind)
                guard mode != .off else { continue }
                let fireDate = mode == .reminder
                    ? occurrence.date.addingTimeInterval(-Double(Self.reminderMinutes) * 60)
                    : occurrence.date
                guard fireDate > now else { continue }

                let id = Self.identifier(city: city, kind: occurrence.kind, date: occurrence.date)
                let request = UNNotificationRequest(
                    identifier: id,
                    content: Self.content(kind: occurrence.kind, at: occurrence.date,
                                          city: city, source: day.times.source, mode: mode),
                    trigger: Self.trigger(for: fireDate, city: city)
                )
                do {
                    try await center.add(request)
                    wanted.insert(id)
                } catch {
                    failed += 1
                    failedIDs.insert(id)
                    azaDebugLog("Aza: prayer notification add failed")
                }
            }
        }

        // Чистим устаревшее, если встало хоть что-то новое: иначе к
        // свежим уведомлениям примешивались бы старые — например,
        // времена прежнего города. А вот полный провал старые запросы
        // сохраняет: лучше устаревшее расписание, чем никакого.
        // Пустой список без ошибок — это НЕ сбой, а осознанный выбор
        // пользователя (все намазы выключены). Старые запросы обязаны
        // уйти, иначе выключённые уведомления продолжали бы приходить.
        // А вот пустой список ИЗ-ЗА ошибок старое расписание сохраняет:
        // устаревшие напоминания лучше молчания.
        guard !wanted.isEmpty || failed == 0 else {
            azaDebugLog("Aza: prayer reschedule failed — keeping old requests")
            return Outcome(scheduled: 0, failed: failed)
        }
        if failed > 0 {
            azaDebugLog("Aza: prayer reschedule partial — replacing what was scheduled")
        }
        let pending = await center.pendingNotificationRequests()
        let stale = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !wanted.contains($0)
                && !failedIDs.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        return Outcome(scheduled: wanted.count, failed: failed)
    }

    /// Диагностика Live QA: сколько уведомлений реально стоит в очереди
    /// и когда сработает ближайшее.
    func logPending() async {
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
        let next = pending
            .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }
            .min()
        let formatter = ISO8601DateFormatter()
        azaDebugLog("Aza: prayer notifications pending=\(pending.count) next=\(next.map(formatter.string(from:)) ?? "-")")
        // Доставленные — ground truth: запрос, ушедший из pending, мог быть
        // и показан, и молча выброшен; различить можно только здесь.
        let delivered = await center.deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix(Self.identifierPrefix) }
            .map { "\($0.request.identifier)@\(formatter.string(from: $0.date))" }
        azaDebugLog("Aza: prayer notifications delivered=[\(delivered.joined(separator: ", "))]")
    }

    func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier)
                .filter { $0.hasPrefix(Self.identifierPrefix) }
        )
    }

    // MARK: Сборка запроса

    private static let identifierPrefix = "aza.prayer."

    /// Детерминированный идентификатор: повторное планирование заменяет
    /// запись, а не плодит дубликаты.
    static func identifier(city: PrayerCity, kind: PrayerKind, date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(identifierPrefix)\(city.id).\(kind.rawValue)."
            + "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    /// Календарный триггер с ЯВНЫМ часовым поясом города: интервальный
    /// таймер поехал бы при переходе на летнее время.
    private static func trigger(for date: Date, city: PrayerCity) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        components.timeZone = city.timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    private static func content(kind: PrayerKind, at date: Date, city: PrayerCity,
                                source: PrayerTimesSource, mode: Mode) -> UNNotificationContent {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = city.timeZone
        let time = formatter.string(from: date)

        let content = UNMutableNotificationContent()
        content.title = mode == .reminder
            ? "\(kind.title) через \(reminderMinutes) мин"
            : kind.title
        content.body = "\(city.name) · \(time)"
        // Источник — в подзаголовке: расчётное время не должно выглядеть
        // как выверенное расписание (§4.3).
        content.subtitle = source.label
        // Звук берём у системы уведомлений, а не проигрываем сами:
        // только так соблюдаются Focus и «Не беспокоить» (§4.4). Плата за
        // это — системный предел в 30 секунд.
        content.sound = sound.fileName
            .map { UNNotificationSound(named: UNNotificationSoundName($0)) } ?? .default
        return content
    }
}

/// Прослушивание звука уведомления в настройках.
///
/// Живёт рядом с уведомлениями, а не отдельным файлом: это тот же список
/// звуков и те же файлы, просто проигранные вручную. Настоящее
/// уведомление по-прежнему звучит через систему — здесь только
/// предварительное прослушивание, поэтому Focus и «Не беспокоить»
/// осознанно не учитываются: пользователь сам нажал.
@MainActor
final class PrayerSoundPreview: ObservableObject {

    /// Что звучит прямо сейчас; nil — тишина. Нужно интерфейсу, чтобы
    /// кнопка показывала «стоп» вместо «играть».
    @Published private(set) var playing: PrayerNotifications.Sound?

    private var player: AVAudioPlayer?
    private var finishWatcher: Task<Void, Never>?

    /// Переключатель: тот же звук останавливает, другой — начинает заново.
    func toggle(_ sound: PrayerNotifications.Sound) {
        guard playing != sound else { return stop() }
        play(sound)
    }

    func play(_ sound: PrayerNotifications.Sound) {
        stop()
        // Системный звук проиграть нечем: у него нет файла, и подменять
        // его чем-то похожим значило бы врать о том, что услышит
        // пользователь.
        guard let name = sound.fileName else { return }
        // Ищем в бандле, где лежит сам класс, а не в Bundle.main: под
        // тестами main — это раннер, и звук молча не находился бы.
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                   withExtension: (name as NSString).pathExtension),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            NSLog("Aza: preview sound is missing from the bundle (%@)", name)
            return
        }
        self.player = player
        playing = sound
        player.play()
        // Кнопка обязана вернуться в исходное состояние сама, когда запись
        // доиграет: иначе она навсегда останется «стоп».
        let seconds = player.duration
        finishWatcher = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 0.1))
            guard !Task.isCancelled else { return }
            self?.finish(sound)
        }
    }

    func stop() {
        finishWatcher?.cancel()
        finishWatcher = nil
        player?.stop()
        player = nil
        playing = nil
    }

    private func finish(_ sound: PrayerNotifications.Sound) {
        guard playing == sound else { return }
        stop()
    }
}
