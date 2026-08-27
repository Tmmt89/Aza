import Adhan
import Foundation

enum PrayerKind: String, CaseIterable, Decodable, Hashable {
    case fajr = "Fajr"
    case sunrise = "Sunrise"
    case dhuhr = "Dhuhr"
    case asr = "Asr"
    case maghrib = "Maghrib"
    case isha = "Isha"

    var title: String {
        switch self {
        case .fajr: "Фаджр"
        case .sunrise: "Восход"
        case .dhuhr: "Зухр"
        case .asr: "Аср"
        case .maghrib: "Магриб"
        case .isha: "Иша"
        }
    }

    var symbol: String {
        switch self {
        case .fajr: "moon.haze.fill"
        case .sunrise: "sunrise.fill"
        case .dhuhr: "sun.max.fill"
        case .asr: "sun.min.fill"
        case .maghrib: "sunset.fill"
        case .isha: "moon.stars.fill"
        }
    }
}

struct PrayerDay: Decodable {
    let date: String
    let times: [String]
}

struct PrayerSource: Decodable {
    let name: String
    let url: String
    let sha256: String

    var shortName: String {
        switch name {
        case "ДУМ Республики Татарстан": "ДУМ РТ"
        case "РДУМ Челябинской области": "РДУМ ЧО"
        default: name
        }
    }
}

struct CityPrayerSchedule: Identifiable, Decodable {
    let id: String
    let name: String
    let timeZone: String
    let coverageStatus: String
    let coverageStart: String
    let coverageEnd: String
    let releaseStatus: String
    let source: PrayerSource
    let days: [PrayerDay]

    var isComplete: Bool { coverageStatus == "complete" }
}

struct PrayerOccurrence {
    let kind: PrayerKind
    let time: String
    let date: Date
    let source: PrayerTimesSource?

    init(kind: PrayerKind, time: String, date: Date, source: PrayerTimesSource? = nil) {
        self.kind = kind
        self.time = time
        self.date = date
        self.source = source
    }

    func countdown(from now: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

struct PrayerCatalog: Decodable {
    let schemaVersion: Int
    let year: Int
    let cityCount: Int
    let completeCityCount: Int
    let partialCityCount: Int
    let cities: [CityPrayerSchedule]
    /// Кто выпустил таблицу («ДУМ ЧР»): подпись обязана быть в интерфейсе
    /// (§4.3). Опционально — старые файлы без поля читаются как прежде.
    let sourceLabel: String?

    static let bundled: PrayerCatalog = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "prayer-schedules-2026", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(PrayerCatalog.self, from: data) else {
            return PrayerCatalog(
                schemaVersion: 1, year: 2026, cityCount: 0,
                completeCityCount: 0, partialCityCount: 0, cities: [],
                sourceLabel: nil
            )
        }
        return catalog
    }()

    func city(id: String) -> CityPrayerSchedule? {
        cities.first { $0.id == id }
    }

    func prayers(cityID: String, on date: Date) -> [PrayerOccurrence] {
        guard let city = city(id: cityID),
              let calendar = calendar(for: city),
              let day = city.days.first(where: { $0.date == dateKey(date, calendar: calendar) }) else {
            return []
        }
        return zip(PrayerKind.allCases, day.times).compactMap { kind, time in
            let parts = time.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let hour = Int(parts[0]), (0..<24).contains(hour),
                  let minute = Int(parts[1]), (0..<60).contains(minute),
                  let occurrenceDate = calendar.date(
                    bySettingHour: hour, minute: minute, second: 0, of: date
                  ) else { return nil }
            return PrayerOccurrence(kind: kind, time: time, date: occurrenceDate)
        }
    }

    func nextPrayer(cityID: String, after now: Date) -> PrayerOccurrence? {
        guard let city = city(id: cityID), let calendar = calendar(for: city) else { return nil }
        for offset in 0...1 {
            guard let localDate = calendar.date(byAdding: .day, value: offset, to: now) else { continue }
            if let prayer = (prayers(cityID: cityID, on: localDate)
                .filter { $0.kind != .sunrise && $0.date > now }
                .min(by: { $0.date < $1.date })) { return prayer }
        }
        return nil
    }

    private func calendar(for city: CityPrayerSchedule) -> Calendar? {
        guard let timeZone = TimeZone(identifier: city.timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func dateKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
