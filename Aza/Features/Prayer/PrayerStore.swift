import Adhan
import Combine
import Foundation
import UserNotifications

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

    /// Города с координатами и часовыми поясами. Координаты — открытые
    /// факты, их публикация не ограничена; расписания ДУМ сюда не входят
    /// (§4.3). Мазхаб: Кавказ — шафиитский, Поволжье, Урал и Сибирь —
    /// ханафитский, как принято в соответствующих муфтиятах.
    static let cities: [PrayerCity] = [
        // Северный Кавказ
        city("grozny", "Грозный", 43.3169, 45.6981, "Europe/Moscow", .shafi),
        city("gudermes", "Гудермес", 43.3528, 46.1064, "Europe/Moscow", .shafi),
        city("urus-martan", "Урус-Мартан", 43.1281, 45.5372, "Europe/Moscow", .shafi),
        city("shali", "Шали", 43.1481, 45.9022, "Europe/Moscow", .shafi),
        city("argun", "Аргун", 43.2939, 45.8697, "Europe/Moscow", .shafi),
        city("makhachkala", "Махачкала", 42.9849, 47.5047, "Europe/Moscow", .shafi),
        city("derbent", "Дербент", 42.0678, 48.2900, "Europe/Moscow", .shafi),
        city("khasavyurt", "Хасавюрт", 43.2506, 46.5872, "Europe/Moscow", .shafi),
        city("kaspiysk", "Каспийск", 42.8897, 47.6406, "Europe/Moscow", .shafi),
        city("nazran", "Назрань", 43.2256, 44.7642, "Europe/Moscow", .shafi),
        city("magas", "Магас", 43.1686, 44.8133, "Europe/Moscow", .shafi),
        city("nalchik", "Нальчик", 43.4981, 43.6189, "Europe/Moscow", .hanafi),
        city("cherkessk", "Черкесск", 44.2269, 42.0578, "Europe/Moscow", .hanafi),
        city("vladikavkaz", "Владикавказ", 43.0370, 44.6675, "Europe/Moscow", .hanafi),
        city("stavropol", "Ставрополь", 45.0428, 41.9734, "Europe/Moscow", .hanafi),
        city("pyatigorsk", "Пятигорск", 44.0486, 43.0594, "Europe/Moscow", .hanafi),
        // Поволжье и Урал
        city("kazan", "Казань", 55.7963, 49.1088, "Europe/Moscow", .hanafi),
        city("naberezhnye", "Набережные Челны", 55.7436, 52.3958, "Europe/Moscow", .hanafi),
        city("almetyevsk", "Альметьевск", 54.9014, 52.2972, "Europe/Moscow", .hanafi),
        city("ufa", "Уфа", 54.7388, 55.9721, "Asia/Yekaterinburg", .hanafi),
        city("sterlitamak", "Стерлитамак", 53.6300, 55.9508, "Asia/Yekaterinburg", .hanafi),
        city("orenburg", "Оренбург", 51.7727, 55.0988, "Asia/Yekaterinburg", .hanafi),
        city("samara", "Самара", 53.1959, 50.1002, "Europe/Samara", .hanafi),
        city("saratov", "Саратов", 51.5336, 46.0343, "Europe/Saratov", .hanafi),
        city("astrakhan", "Астрахань", 46.3497, 48.0408, "Europe/Astrakhan", .hanafi),
        city("volgograd", "Волгоград", 48.7080, 44.5133, "Europe/Volgograd", .hanafi),
        city("nizhny", "Нижний Новгород", 56.3269, 44.0059, "Europe/Moscow", .hanafi),
        city("perm", "Пермь", 58.0105, 56.2502, "Asia/Yekaterinburg", .hanafi),
        city("yekaterinburg", "Екатеринбург", 56.8389, 60.6057, "Asia/Yekaterinburg", .hanafi),
        city("chelyabinsk", "Челябинск", 55.1644, 61.4368, "Asia/Yekaterinburg", .hanafi),
        city("tyumen", "Тюмень", 57.1522, 65.5272, "Asia/Yekaterinburg", .hanafi),
        // Столицы и крупные города
        city("moscow", "Москва", 55.7558, 37.6173, "Europe/Moscow", .hanafi),
        city("spb", "Санкт-Петербург", 59.9311, 30.3609, "Europe/Moscow", .hanafi),
        city("kaliningrad", "Калининград", 54.7104, 20.4522, "Europe/Kaliningrad", .hanafi),
        city("rostov", "Ростов-на-Дону", 47.2357, 39.7015, "Europe/Moscow", .hanafi),
        city("krasnodar", "Краснодар", 45.0355, 38.9753, "Europe/Moscow", .hanafi),
        city("sochi", "Сочи", 43.5855, 39.7231, "Europe/Moscow", .hanafi),
        city("simferopol", "Симферополь", 44.9521, 34.1024, "Europe/Simferopol", .hanafi),
        city("novosibirsk", "Новосибирск", 55.0084, 82.9357, "Asia/Novosibirsk", .hanafi),
        city("omsk", "Омск", 54.9885, 73.3242, "Asia/Omsk", .hanafi),
        city("krasnoyarsk", "Красноярск", 56.0184, 92.8672, "Asia/Krasnoyarsk", .hanafi),
        city("irkutsk", "Иркутск", 52.2870, 104.3050, "Asia/Irkutsk", .hanafi),
        city("vladivostok", "Владивосток", 43.1155, 131.8855, "Asia/Vladivostok", .hanafi),
        // За пределами России — где чаще всего бывают
        city("baku", "Баку", 40.4093, 49.8671, "Asia/Baku", .shafi),
        city("tbilisi", "Тбилиси", 41.7151, 44.8271, "Asia/Tbilisi", .hanafi),
        city("istanbul", "Стамбул", 41.0082, 28.9784, "Europe/Istanbul", .hanafi),
        city("dubai", "Дубай", 25.2048, 55.2708, "Asia/Dubai", .shafi),
        city("mecca", "Мекка", 21.3891, 39.8579, "Asia/Riyadh", .shafi),
        city("medina", "Медина", 24.5247, 39.5692, "Asia/Riyadh", .shafi),
        city("cairo", "Каир", 30.0444, 31.2357, "Africa/Cairo", .shafi),
        city("almaty", "Алматы", 43.2220, 76.8512, "Asia/Almaty", .hanafi),
        city("karaganda", "Караганда", 49.8047, 73.1094, "Asia/Almaty", .hanafi),
        city("tashkent", "Ташкент", 41.2995, 69.2401, "Asia/Tashkent", .hanafi),
        city("bishkek", "Бишкек", 42.8746, 74.5698, "Asia/Bishkek", .hanafi),
        city("berlin", "Берлин", 52.5200, 13.4050, "Europe/Berlin", .hanafi),
        city("london", "Лондон", 51.5074, -0.1278, "Europe/London", .hanafi),
        city("prague", "Прага", 50.0755, 14.4378, "Europe/Prague", .hanafi),
    ]
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

    /// Метод расчёта у всех один — Muslim World League: пока авторитетные
    /// параметры конкретных муфтиятов не подтверждены, честнее назвать
    /// один общий метод, чем выдавать его за чужой.
    private static func city(_ id: String, _ name: String,
                             _ latitude: Double, _ longitude: Double,
                             _ timeZone: String, _ madhab: Madhab) -> PrayerCity {
        PrayerCity(id: id, name: name, latitude: latitude, longitude: longitude,
                   timeZoneID: timeZone, madhab: madhab, method: .muslimWorldLeague)
    }

    /// Полный список для выбора: наши города с координатами плюс города
    /// из установленного каталога расписаний. У последних координат нет —
    /// они работают по готовой таблице, а не по расчёту.
    /// Каталог берётся ВНУТРИ, а не значением по умолчанию: значения по
    /// умолчанию вычисляются в контексте вызывающего, а он бывает вне
    /// главного актора — в Swift 6 это уже ошибка, а не предупреждение.
    static func availableCities(catalog: PrayerCatalog? = nil) -> [PrayerCity] {
        let catalog = catalog ?? ScheduleTablePrayerProvider.userProvided()?.catalog
        var result = cities
        // Множество пополняется на ходу: один город приходит из каждого
        // годового файла, и без этого он попал бы в список несколько раз —
        // с одинаковым названием и разными идентификаторами.
        var known = Set(cities.map { PrayerCatalog.normalized($0.name) })
        for entry in catalog?.cities ?? [] {
            let key = PrayerCatalog.normalized(entry.name)
            guard known.insert(key).inserted else { continue }
            result.append(PrayerCity(
                id: "catalog:" + key, name: entry.name,
                latitude: nil, longitude: nil,
                timeZoneID: entry.timeZone, madhab: .hanafi,
                method: .muslimWorldLeague))
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Уведомления берут времена ОТСЮДА же: иначе они разошлись бы с тем,
    /// что показано на экране, вместе с подписью источника.
    let notifications = PrayerNotifications()
    @Published private(set) var notificationsEnabled = UserDefaults.standard
        .bool(forKey: "PrayerNotificationsEnabled")
    /// Непустая строка — расписание уведомлений неполное. Показывается
    /// пользователю: тихо потерять напоминание о намазе нельзя.
    @Published private(set) var notificationIssue: String?

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
        selectedCityID = allCities.contains { $0.id == stored } ? stored : nil
        if selectedCityID == nil { refresh() }
    }

    /// Города для выбора: с координатами и/или с расписанием.
    private(set) lazy var allCities: [PrayerCity] = Self.availableCities()

    var selectedCity: PrayerCity? {
        allCities.first { $0.id == selectedCityID }
    }

    var source: PrayerTimesSource? { today?.source }

    /// Есть ли для выбранного города готовая таблица. Пользователь должен
    /// понимать, что показано: выверенное расписание или наш расчёт.
    var hasVerifiedTable: Bool { today?.source.isVerifiedTable == true }

    /// Почему времён нет — одна формулировка на все экраны. Пустой экран
    /// без причины пользователь читает как поломку.
    var unavailableReason: String? {
        guard today == nil else { return nil }
        guard selectedCity != nil else {
            return "Выберите город, чтобы видеть время намаза"
        }
        return "Расписание не покрывает сегодняшний день, а рассчитать нечем — выберите ближайший крупный город"
    }

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
        azaDebugLog("Aza: prayer source=\(today?.source.label ?? "-") table=\(today?.source.isVerifiedTable == true ? 1 : 0) city=\(city.name)")
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
            let outcome = await notifications.reschedule(days: snapshot, city: city, now: now)
            await notifications.logPending()
            // Очередь может быть полной, а разрешения — не быть: система
            // принимает запросы и без него, но в момент намаза молча их
            // выбрасывает. Это главный источник «звука не было».
            let auth = await notifications.authorizationStatus()
            azaDebugLog("Aza: prayer notif authorization=\(auth.rawValue)")
            guard !Task.isCancelled else { return }
            if auth != .authorized {
                self.notificationIssue = "Нет разрешения на уведомления — включите Aza в Системных настройках → Уведомления"
            } else {
                self.notificationIssue = outcome.isComplete
                    ? nil
                    : (outcome.scheduled == 0
                       ? "Уведомления о намазе не поставлены — проверьте разрешение в Системных настройках"
                       : "Часть уведомлений не поставлена (\(outcome.failed)) — расписание неполное")
            }
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
