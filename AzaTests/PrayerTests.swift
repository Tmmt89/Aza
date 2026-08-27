import Adhan
import XCTest

@MainActor
final class PrayerTests: XCTestCase {
    private let grozny = PrayerCity(
        id: "grozny", name: "Грозный", latitude: 43.3169, longitude: 45.6981,
        timeZoneID: "Europe/Moscow", madhab: .shafi, method: .muslimWorldLeague
    )

    func testCalculatedGroznyTimesOnFixedDate() throws {
        let date = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 12)
        ))
        let times = try XCTUnwrap(CalculatedPrayerProvider().times(on: date, city: grozny))
        XCTAssertEqual(PrayerKind.allCases.compactMap { times.time(for: $0).map(grozny.formattedTime) },
                       ["03:31", "05:15", "12:00", "15:43", "18:41", "20:18"])
        XCTAssertEqual(times.source.label, "Расчёт MWL")
    }

    func testTablePriorityAndMalformedTableRejection() throws {
        let date = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27)
        ))
        let source = PrayerSource(name: "ДУМ ЧР", url: "", sha256: "fixture")
        let day = PrayerDay(date: "2026-08-27",
                            times: ["04:00", "05:30", "12:10", "16:00", "18:50", "20:30"])
        let city = CityPrayerSchedule(
            id: grozny.id, name: grozny.name, timeZone: grozny.timeZoneID,
            coverageStatus: "partial", coverageStart: day.date, coverageEnd: day.date,
            releaseStatus: "test", source: source, days: [day]
        )
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 1,
            completeCityCount: 0, partialCityCount: 1, cities: [city], sourceLabel: "ДУМ ЧР"
        )
        let preferred = try XCTUnwrap(PrayerStore.preferredTimes(
            for: grozny, on: date,
            table: ScheduleTablePrayerProvider(catalog: catalog),
            calculated: CalculatedPrayerProvider()
        ))
        XCTAssertTrue(preferred.source.isVerifiedTable)
        XCTAssertEqual(preferred.source.label, "ДУМ ЧР")
        XCTAssertEqual(preferred.fajr.map(grozny.formattedTime), "04:00")

        let malformedCity = CityPrayerSchedule(
            id: grozny.id, name: grozny.name, timeZone: grozny.timeZoneID,
            coverageStatus: "partial", coverageStart: day.date, coverageEnd: day.date,
            releaseStatus: "test", source: source,
            days: [.init(date: day.date,
                         times: ["04:00", "05:30", "12:x", "16:00", "18:50", "20:30"])]
        )
        let malformed = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 1,
            completeCityCount: 0, partialCityCount: 1,
            cities: [malformedCity], sourceLabel: "ДУМ ЧР"
        )
        XCTAssertNil(ScheduleTablePrayerProvider(catalog: malformed).times(on: date, city: grozny))
    }

    func testHighLatitudeCaveatAndCityTimezoneFormatting() throws {
        let spb = PrayerCity(
            id: "spb", name: "Санкт-Петербург", latitude: 59.9311, longitude: 30.3609,
            timeZoneID: "Europe/Moscow", madhab: .hanafi, method: .muslimWorldLeague
        )
        let date = try XCTUnwrap(spb.calendar.date(
            from: DateComponents(year: 2026, month: 6, day: 21, hour: 12)
        ))
        XCTAssertNotNil(CalculatedPrayerProvider().times(on: date, city: spb)?.source.caveat)

        let instant = try XCTUnwrap(ISO8601DateFormatter()
            .date(from: "2026-08-27T15:41:00Z"))
        let ufa = PrayerCity(
            id: "ufa", name: "Уфа", latitude: 54.7388, longitude: 55.9721,
            timeZoneID: "Asia/Yekaterinburg", madhab: .hanafi, method: .muslimWorldLeague
        )
        XCTAssertEqual(ufa.formattedTime(instant), "20:41")
    }

    func testNotificationIdentifierIsStableForShiftedTime() throws {
        let morning = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 3, minute: 31)
        ))
        let shifted = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27, hour: 4)
        ))
        let tomorrow = try XCTUnwrap(grozny.calendar.date(byAdding: .day, value: 1, to: morning))
        XCTAssertEqual(PrayerNotifications.identifier(city: grozny, kind: .fajr, date: morning),
                       PrayerNotifications.identifier(city: grozny, kind: .fajr, date: shifted))
        XCTAssertNotEqual(PrayerNotifications.identifier(city: grozny, kind: .fajr, date: morning),
                          PrayerNotifications.identifier(city: grozny, kind: .fajr, date: tomorrow))
    }
}
