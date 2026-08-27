import Adhan
import Combine
import Foundation

/// Времена намаза для интерфейса: выбранный город, расписание на день,
/// ближайший намаз и ЧЕСТНАЯ подпись источника (§4.3).
///
/// Порядок источников — как просил владелец и требует спецификация:
/// готовая таблица, если она есть для этого города и дня; иначе расчёт.
/// Молча метод не подменяется: подпись всегда показывает, что сработало.
@MainActor
final class PrayerStore: ObservableObject {

    static let cityStorageKey = "selectedPrayerCityID"

    @Published private(set) var today: DayPrayerTimes?
    @Published var selectedCityID: String? {
        didSet {
            UserDefaults.standard.set(selectedCityID, forKey: Self.cityStorageKey)
            refresh()
            scheduleRollover()
        }
    }

    /// Города с координатами и часовыми поясами. Координаты — факты,
    /// их публикация не ограничена; расписания ДУМ сюда не входят.
    static let cities: [PrayerCity] = [
        PrayerCity(id: "grozny", name: "Грозный", latitude: 43.3169, longitude: 45.6981,
                   timeZoneID: "Europe/Moscow", madhab: .shafi, method: .muslimWorldLeague),
        PrayerCity(id: "moscow", name: "Москва", latitude: 55.7558, longitude: 37.6173,
                   timeZoneID: "Europe/Moscow", madhab: .hanafi, method: .muslimWorldLeague),
        PrayerCity(id: "kazan", name: "Казань", latitude: 55.7963, longitude: 49.1088,
                   timeZoneID: "Europe/Moscow", madhab: .hanafi, method: .muslimWorldLeague),
        PrayerCity(id: "spb", name: "Санкт-Петербург", latitude: 59.9311, longitude: 30.3609,
                   timeZoneID: "Europe/Moscow", madhab: .hanafi, method: .muslimWorldLeague),
        PrayerCity(id: "makhachkala", name: "Махачкала", latitude: 42.9849, longitude: 47.5047,
                   timeZoneID: "Europe/Moscow", madhab: .shafi, method: .muslimWorldLeague),
        PrayerCity(id: "ufa", name: "Уфа", latitude: 54.7388, longitude: 55.9721,
                   timeZoneID: "Asia/Yekaterinburg", madhab: .hanafi, method: .muslimWorldLeague),
    ]

    /// Уведомления берут времена ОТСЮДА же: иначе они разошлись бы с тем,
    /// что показано на экране, вместе с подписью источника.
    let notifications = PrayerNotifications()
    @Published private(set) var notificationsEnabled = UserDefaults.standard
        .bool(forKey: "PrayerNotificationsEnabled")

    /// Одна задача планирования за раз: параллельные пересборки могли
    /// снять только что добавленное уведомление или вернуть устаревший
    /// текст поверх нового.
    private var schedulingTask: Task<Void, Never>?

    private let calculated = CalculatedPrayerProvider()
    private var table: ScheduleTablePrayerProvider?
    private var rolloverTimer: Timer?
    private var settingsRestored = false

    init() {
        table = ScheduleTablePrayerProvider.userProvided()
        // Настройки читаем НЕ здесь: AzaApp.init выполняется до того, как
        // песочница подключит контейнер параметров, и UserDefaults в этот
        // момент отдаёт пустоту — выбранный город «терялся» при каждом
        // запуске. Первый же виток главного цикла уже видит контейнер.
        DispatchQueue.main.async { [weak self] in
            self?.loadPersistedCity()
        }
    }

    /// Восстанавливает выбор города из настроек. Города не подставляем
    /// молча: чужой город — это чужое расписание, поэтому неизвестный
    /// идентификатор даёт nil и просьбу выбрать.
    private func loadPersistedCity() {
        // Однократно и только если пользователь ещё ничего не выбрал сам:
        // отложенное восстановление не должно перебить свежий выбор.
        guard !settingsRestored else { return }
        settingsRestored = true
        notificationsEnabled = UserDefaults.standard.bool(forKey: "PrayerNotificationsEnabled")
        guard selectedCityID == nil else {
            refresh()
            return
        }
        let stored = UserDefaults.standard.string(forKey: Self.cityStorageKey)
        azaDebugLog("Aza: prayer settings loaded city=\(stored ?? "-")")
        // Присваивание запускает didSet: refresh и перевзвод таймера
        // произойдут там, второй раз их звать не нужно.
        selectedCityID = Self.cities.contains { $0.id == stored } ? stored : nil
        if selectedCityID == nil { refresh() }
    }

    var selectedCity: PrayerCity? {
        Self.cities.first { $0.id == selectedCityID }
    }

    var source: PrayerTimesSource? { today?.source }

    /// Ближайший намаз: ищем в сегодняшнем дне, затем в завтрашнем —
    /// после иши сегодняшний список пуст.
    func nextPrayer(after now: Date = .now)
        -> (kind: PrayerKind, date: Date, source: PrayerTimesSource)? {
        if let upcoming = today?.occurrences.first(where: { $0.date > now }) {
            return upcoming
        }
        guard let city = selectedCity,
              let tomorrow = city.calendar.date(byAdding: .day, value: 1, to: now),
              let times = times(for: city, on: tomorrow) else { return nil }
        return times.occurrences.first { $0.date > now }
    }

    func refresh(now: Date = .now) {
        guard let city = selectedCity else {
            today = nil
            cancelNotifications()
            return
        }
        today = times(for: city, on: now)
        rescheduleNotifications(now: now)
    }

    /// Включение спрашивает разрешение (§9: не при запуске, а по действию).
    func setNotifications(enabled: Bool) async {
        if enabled, await notifications.requestAuthorization() == false {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: "PrayerNotificationsEnabled")
            return
        }
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "PrayerNotificationsEnabled")
        if enabled {
            rescheduleNotifications()
        } else {
            cancelNotifications()
        }
    }

    /// Недельный горизонт из тех же провайдеров, что рисуют расписание.
    func rescheduleNotifications(now: Date = .now) {
        azaDebugLog("Aza: prayer reschedule enabled=\(notificationsEnabled ? 1 : 0) city=\(selectedCityID ?? "-")")
        guard notificationsEnabled, let city = selectedCity else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        var days: [(date: Date, times: DayPrayerTimes)] = []
        for offset in 0..<PrayerNotifications.horizonDays {
            guard let date = calendar.date(byAdding: .day, value: offset, to: now),
                  let times = times(for: city, on: date) else { continue }
            days.append((date, times))
        }
        let snapshot = days
        let previous = schedulingTask
        schedulingTask = Task { [notifications] in
            // Ждём предыдущую пересборку, а не бежим с ней наперегонки.
            await previous?.value
            await notifications.reschedule(days: snapshot, city: city, now: now)
            await notifications.logPending()
        }
    }

    /// Перед удалением данных: гасим планировщик, чтобы незавершённая
    /// пересборка не вернула уведомления после их снятия.
    func shutdownForCleanup() async {
        notificationsEnabled = false
        let running = schedulingTask
        schedulingTask = nil
        running?.cancel()
        await running?.value
        await notifications.cancelAll()
    }

    /// Снятие уведомлений — через ту же очередь, что и планирование:
    /// иначе выключение обгоняло бы незавершённую пересборку, и та
    /// возвращала бы уведомления обратно.
    private func cancelNotifications() {
        let previous = schedulingTask
        schedulingTask = Task { [notifications] in
            await previous?.value
            await notifications.cancelAll()
        }
    }

    /// §4.3: таблица приоритетна, расчёт — резерв.
    private func times(for city: PrayerCity, on date: Date) -> DayPrayerTimes? {
        Self.preferredTimes(for: city, on: date, table: table, calculated: calculated)
    }

    static func preferredTimes(for city: PrayerCity, on date: Date,
                               table: ScheduleTablePrayerProvider?,
                               calculated: CalculatedPrayerProvider) -> DayPrayerTimes? {
        if let table, let fromTable = table.times(on: date, city: city) {
            return fromTable
        }
        return calculated.times(on: date, city: city)
    }

    /// Пересчёт на границе местных суток, а не «через 24 часа»: переход
    /// на летнее время и смена часового пояса иначе сдвинут расписание.
    private func scheduleRollover() {
        rolloverTimer?.invalidate()
        guard let city = selectedCity else { return }
        guard let midnight = city.calendar.nextDate(after: Date(),
                                               matching: DateComponents(hour: 0, minute: 0),
                                               matchingPolicy: .nextTime) else { return }
        let timer = Timer(fire: midnight, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleRollover()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        rolloverTimer = timer
    }
}
