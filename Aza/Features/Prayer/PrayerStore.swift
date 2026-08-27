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

    private let calculated = CalculatedPrayerProvider()
    private var table: ScheduleTablePrayerProvider?
    private var rolloverTimer: Timer?

    init() {
#if DEBUG
        assert(PrayerScheduleChecks.run())
#endif
        let stored = UserDefaults.standard.string(forKey: Self.cityStorageKey)
        // Города не подставляем молча: чужой город — это чужое расписание.
        // Нет выбора или город исчез — интерфейс попросит выбрать.
        selectedCityID = Self.cities.contains { $0.id == stored } ? stored : nil
        table = ScheduleTablePrayerProvider.userProvided()
        refresh()
        scheduleRollover()
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
            return
        }
        today = times(for: city, on: now)
    }

    /// §4.3: таблица приоритетна, расчёт — резерв.
    private func times(for city: PrayerCity, on date: Date) -> DayPrayerTimes? {
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
