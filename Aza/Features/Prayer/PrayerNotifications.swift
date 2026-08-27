import Foundation
import UserNotifications

/// Уведомления о намазе (§4.4).
///
/// Полный азан и звуки природы отложены сознательно: спецификация их
/// перечисляет, но звука со свободной лицензией у проекта пока нет, а
/// класть в MIT-сборку чужую запись нельзя (§15). Сейчас — системное
/// уведомление и предварительное напоминание.
@MainActor
final class PrayerNotifications {

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

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Пересобирает расписание уведомлений: сначала добавляет нужные
    /// (одинаковый идентификатор ЗАМЕНЯЕТ запись, а не дублирует), затем
    /// снимает устаревшие. Обратный порядок — «снять всё, потом added» —
    /// оставлял бы окно, в котором ближайшее уведомление уже снято, но
    /// ещё не поставлено.
    func reschedule(days: [(date: Date, times: DayPrayerTimes)],
                    city: PrayerCity,
                    now: Date = .now) async {
        var wanted: Set<String> = []
        var hadFailures = false

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
                    hadFailures = true
                    azaDebugLog("Aza: prayer notification add failed")
                }
            }
        }

        // Чистим устаревшее ТОЛЬКО если новое расписание встало целиком.
        // Иначе неудачная постановка сняла бы старые уведомления, не
        // поставив новые, и пользователь остался бы вообще без напоминаний.
        guard !hadFailures else {
            azaDebugLog("Aza: prayer reschedule incomplete — keeping old requests")
            return
        }
        let pending = await center.pendingNotificationRequests()
        let stale = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) && !wanted.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
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
        content.sound = .default
        return content
    }
}
