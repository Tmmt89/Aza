import Adhan
import Foundation

/// Времена одного дня. Отвязаны от Adhan: источником может быть и
/// готовая таблица ДУМ, и расчёт.
struct DayPrayerTimes {
    /// Абсолютные моменты; отсутствующий намаз (полярный день) — nil.
    var fajr: Date?
    var sunrise: Date?
    var dhuhr: Date?
    var asr: Date?
    var maghrib: Date?
    var isha: Date?

    /// Кто дал эти времена и насколько им можно верить (§4.3: источник
    /// обязан быть назван в интерфейсе).
    var source: PrayerTimesSource

    func time(for kind: PrayerKind) -> Date? {
        switch kind {
        case .fajr: fajr
        case .sunrise: sunrise
        case .dhuhr: dhuhr
        case .asr: asr
        case .maghrib: maghrib
        case .isha: isha
        }
    }

    var occurrences: [(kind: PrayerKind, date: Date, source: PrayerTimesSource)] {
        PrayerKind.allCases.compactMap { kind in
            time(for: kind).map { (kind, $0, source) }
        }
    }
}

/// Происхождение времён — показывается пользователю дословно.
struct PrayerTimesSource: Equatable {
    /// Короткая подпись под расписанием: «ДУМ ЧР», «Расчёт MWL».
    let label: String
    /// true — это готовая таблица (приоритетный источник по §4.3).
    let isVerifiedTable: Bool
    /// Честная оговорка: например, приближение для высоких широт.
    var caveat: String?
}

/// Источник времён намаза. Порядок §4.3: сначала проверенная таблица,
/// затем расчёт, затем ручные настройки пользователя.
protocol PrayerTimesProvider {
    /// nil — источник не знает этот день (таблица кончилась, нет города).
    func times(on date: Date, city: PrayerCity) -> DayPrayerTimes?
}

/// Город с координатами и часовым поясом. Координаты — факт, а не чужие
/// данные, поэтому лежат в открытом репозитории.
struct PrayerCity: Identifiable, Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// Идентификатор IANA: считать день нужно в местном календаре, иначе
    /// «сегодня» уедет на сутки, а переход на летнее время сдвинет времена.
    let timeZoneID: String
    /// Мазхаб влияет на время аср: ДУМ ЧР — шафиитский.
    let madhab: Madhab
    let method: CalculationMethod

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneID) ?? .current
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// Пока авторитетные параметры ДУМ РФ не подтверждены документально,
    /// подпись называет фактический метод расчёта, а не орган.
    var calculationLabel: String {
        switch method {
        case .muslimWorldLeague: "Расчёт MWL"
        case .egyptian: "Расчёт (Египет)"
        case .karachi: "Расчёт (Карачи)"
        case .ummAlQura: "Расчёт (Умм аль-Кура)"
        case .turkey: "Расчёт (Турция)"
        default: "Расчёт"
        }
    }
}

/// Астрономический расчёт (adhan-swift, MIT). Резервный источник §4.3:
/// работает офлайн для любого города, но не заменяет проверенную таблицу.
struct CalculatedPrayerProvider: PrayerTimesProvider {

    /// Севернее этой широты Adhan подменяет недостижимые углы правилом
    /// «седьмая часть ночи» и НЕ сообщает об этом. Мы говорим прямо.
    private static let highLatitudeThreshold = 48.0

    func times(on date: Date, city: PrayerCity) -> DayPrayerTimes? {
        let coordinates = Coordinates(latitude: city.latitude, longitude: city.longitude)
        let components = city.calendar.dateComponents([.year, .month, .day], from: date)

        var params = city.method.params
        params.madhab = city.madhab
        params.highLatitudeRule = .recommended(for: coordinates)

        guard let times = PrayerTimes(coordinates: coordinates,
                                      date: components,
                                      calculationParameters: params) else {
            return nil
        }

        let isHighLatitude = abs(city.latitude) > Self.highLatitudeThreshold
        let source = PrayerTimesSource(
            label: city.calculationLabel,
            isVerifiedTable: false,
            caveat: isHighLatitude
                ? "Высокие широты: фаджр и иша рассчитаны приближённо (1/7 ночи)"
                : nil
        )
        return DayPrayerTimes(
            fajr: times.fajr, sunrise: times.sunrise, dhuhr: times.dhuhr,
            asr: times.asr, maghrib: times.maghrib, isha: times.isha,
            source: source
        )
    }
}

/// Готовая таблица (ДУМ ЧР, ДУМ РТ и т.п.) — приоритетный источник.
/// Данные в публичный MIT-репозиторий не кладутся (спецификация §4.3):
/// таблицы читаются из Application Support/Aza/prayer-schedules, куда их
/// кладёт пользователь или установщик с оговорёнными правами.
struct ScheduleTablePrayerProvider: PrayerTimesProvider {
    let catalog: PrayerCatalog

    private static let maximumCatalogBytes = 10 * 1024 * 1024

    /// Каталог из папки пользователя; пустой, если таблиц нет.
    static func userProvided() -> ScheduleTablePrayerProvider? {
        let directory = ClipboardStore.defaultStorageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("prayer-schedules", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = boundedData(from: file),
                  let catalog = try? JSONDecoder().decode(PrayerCatalog.self, from: data),
                  !catalog.cities.isEmpty else { continue }
            return ScheduleTablePrayerProvider(catalog: catalog)
        }
        return nil
    }

    func times(on date: Date, city: PrayerCity) -> DayPrayerTimes? {
        guard let tableCity = catalog.city(id: city.id),
              tableCity.timeZone == city.timeZoneID else { return nil }
        let occurrences = catalog.prayers(cityID: city.id, on: date)
        guard occurrences.count == PrayerKind.allCases.count,
              occurrences.map(\.date) == occurrences.map(\.date).sorted() else { return nil }
        let label = (catalog.sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? tableCity.source.shortName
        guard !label.isEmpty else { return nil }
        var result = DayPrayerTimes(
            source: PrayerTimesSource(label: label, isVerifiedTable: true)
        )
        for occurrence in occurrences {
            switch occurrence.kind {
            case .fajr: result.fajr = occurrence.date
            case .sunrise: result.sunrise = occurrence.date
            case .dhuhr: result.dhuhr = occurrence.date
            case .asr: result.asr = occurrence.date
            case .maghrib: result.maghrib = occurrence.date
            case .isha: result.isha = occurrence.date
            }
        }
        return result
    }

    private static func boundedData(from file: URL) -> Data? {
        guard let values = try? file.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ), values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumCatalogBytes + 1),
              data.count <= maximumCatalogBytes else { return nil }
        return data
    }
}
