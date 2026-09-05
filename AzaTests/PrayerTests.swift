import Adhan
import AVFoundation
import UserNotifications
import XCTest

@MainActor
final class PrayerTests: XCTestCase {
    private let grozny = PrayerCity(
        id: "grozny", name: "Грозный", latitude: 43.3169, longitude: 45.6981,
        timeZoneID: "Europe/Moscow", madhab: .shafi, method: .muslimWorldLeague
    )

    func testMenuBarFormatsUseScheduleTimeAndRoundCountdownUp() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let next = PrayerOccurrence(kind: .dhuhr, time: "12:30", date: now.addingTimeInterval(3661))
        XCTAssertNil(MenuBarDisplay.logo.text(for: next, now: now))
        XCTAssertEqual(MenuBarDisplay.prayer.text(for: next, now: now), "Зухр 12:30")
        XCTAssertEqual(MenuBarDisplay.time.text(for: next, now: now), "12:30")
        XCTAssertEqual(MenuBarDisplay.countdown.text(for: next, now: now), "Зухр · 1 ч 2 мин")
        XCTAssertEqual(MenuBarDisplay.countdown.text(for: next, now: next.date.addingTimeInterval(-60)),
                       "Зухр · 1 мин")
        XCTAssertEqual(MenuBarDisplay.countdown.text(for: next, now: next.date.addingTimeInterval(-0.1)),
                       "Зухр · 1 мин")
        for mode in MenuBarDisplay.allCases {
            XCTAssertNil(mode.text(for: nil, now: now), "Без расписания остаётся знак Aza")
            XCTAssertEqual(MenuBarDisplay(rawValue: mode.rawValue), mode)
        }
        for kind in PrayerKind.allCases {
            let occurrence = PrayerOccurrence(kind: kind, time: "04:07", date: now.addingTimeInterval(86400))
            XCTAssertEqual(MenuBarDisplay.prayer.text(for: occurrence, now: now), "\(kind.title) 04:07")
        }
    }

    func testPrayerArrivalLastsTwoMinutesAndDoesNotCelebrateSunrise() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let fajr = PrayerOccurrence(kind: .fajr, time: "04:07", date: start)
        let sunrise = PrayerOccurrence(kind: .sunrise, time: "05:30",
                                       date: start.addingTimeInterval(4_980))
        let schedule = [fajr, sunrise]
        XCTAssertNil(PrayerOccurrence.current(in: schedule, at: start.addingTimeInterval(-1)))
        XCTAssertEqual(PrayerOccurrence.current(in: schedule, at: start)?.kind, .fajr)
        XCTAssertEqual(PrayerOccurrence.current(in: schedule, at: start.addingTimeInterval(119.9))?.kind, .fajr)
        XCTAssertNil(PrayerOccurrence.current(in: schedule, at: start.addingTimeInterval(120)))
        XCTAssertNil(PrayerOccurrence.current(in: schedule, at: sunrise.date))
        XCTAssertNil(PrayerOccurrence.current(in: [], at: start))
    }

    func testDictationPauseWaitsForAddThenCancelsAndConfirmsEmpty() async {
        var calls: [String] = []
        let pendingAdd = Task { @MainActor in
            await Task.yield()
            calls.append("add finished")
        }
        let ready = await PrayerNotifications.pause(
            after: pendingAdd,
            cancel: { calls.append("cancel") },
            pendingEmpty: { calls.append("confirmed empty"); return true })
        XCTAssertTrue(ready)
        XCTAssertEqual(calls, ["add finished", "cancel", "confirmed empty"],
                       "микрофон ждёт завершения add и подтверждённого снятия очереди")

        let uncleared = await PrayerNotifications.pause(
            after: nil, cancel: {}, pendingEmpty: { false })
        XCTAssertFalse(uncleared, "оставшиеся уведомления запрещают запуск микрофона")
        let now = Date()
        XCTAssertNil(PrayerNotifications.fireDate(kind: .fajr, at: now, now: now),
                     "после паузы прошедший намаз не ставится заново")
    }

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
        let source = PrayerSource(name: "ДУМ ЧР", url: "https://example.org/schedule.xlsx", sha256: "fixture")
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

        for days in [
            [PrayerDay(date: day.date, times: ["04:00", "04:00", "12:10", "16:00", "18:50", "20:30"])],
            [day, PrayerDay(date: day.date, times: ["04:10", "05:30", "12:10", "16:00", "18:50", "20:30"])],
        ] {
            let invalid = CityPrayerSchedule(
                id: grozny.id, name: grozny.name, timeZone: grozny.timeZoneID,
                coverageStatus: "partial", coverageStart: day.date, coverageEnd: day.date,
                releaseStatus: "test", source: source, days: days)
            let catalog = PrayerCatalog(
                schemaVersion: 1, year: 2026, cityCount: 1,
                completeCityCount: 0, partialCityCount: 1, cities: [invalid], sourceLabel: nil)
            XCTAssertNil(ScheduleTablePrayerProvider(catalog: catalog).times(on: date, city: grozny),
                         "одновременные намазы и неоднозначные строки не являются выверенным расписанием")
        }
    }

    /// Регрессия 02.09: кэш `today` пережил полночь (Mac спал), все его
    /// времена оказались в прошлом, и nextPrayer прыгал на послезавтра —
    /// «через 25 часов» при намазе через час. Ближайший намаз обязан
    /// считаться от `now`, без оглядки на какой-либо кэш.
    func testNextPrayerBeforeFajrPicksTodayNotDayAfterTomorrow() throws {
        let source = PrayerSource(name: "ДУМ ЧР", url: "https://example.org/schedule.xlsx", sha256: "fixture")
        let city = CityPrayerSchedule(
            id: grozny.id, name: grozny.name, timeZone: grozny.timeZoneID,
            coverageStatus: "partial", coverageStart: "2026-09-01", coverageEnd: "2026-09-03",
            releaseStatus: "test", source: source,
            days: [
                .init(date: "2026-09-01", times: ["04:02", "05:16", "12:30", "15:45", "18:37", "20:06"]),
                .init(date: "2026-09-02", times: ["04:04", "05:17", "12:30", "15:44", "18:36", "20:04"]),
                .init(date: "2026-09-03", times: ["04:05", "05:18", "12:30", "15:44", "18:34", "20:02"]),
            ]
        )
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 1,
            completeCityCount: 0, partialCityCount: 1, cities: [city], sourceLabel: "ДУМ ЧР"
        )
        let table = ScheduleTablePrayerProvider(catalog: catalog)
        let calculated = CalculatedPrayerProvider()

        // 03:02 ночи 2 сентября: до сегодняшнего фаджра час.
        let beforeFajr = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 2, hour: 3, minute: 2)))
        let next = try XCTUnwrap(PrayerStore.nextPrayer(
            after: beforeFajr, for: grozny, table: table, calculated: calculated))
        XCTAssertEqual(next.kind, .fajr)
        XCTAssertEqual(grozny.formattedTime(next.date), "04:04")
        XCTAssertEqual(next.date.timeIntervalSince(beforeFajr), 62 * 60)

        // После иши ближайший — завтрашний фаджр.
        let afterIsha = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 2, hour: 21)))
        let tomorrow = try XCTUnwrap(PrayerStore.nextPrayer(
            after: afterIsha, for: grozny, table: table, calculated: calculated))
        XCTAssertEqual(tomorrow.kind, .fajr)
        XCTAssertEqual(grozny.formattedTime(tomorrow.date), "04:05")
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

    /// Правило исследования: источники не смешиваются молча. День вне
    /// покрытия таблицы обязан считаться расчётом И сменить подпись —
    /// иначе расчётное время выглядело бы как выверенное расписание.
    func testDayOutsideTableCoverageFallsBackAndRelabels() throws {
        let source = PrayerSource(name: "РДУМ ЧО", url: "https://example.org/schedule.xlsx", sha256: "fixture")
        let covered = PrayerDay(date: "2026-08-27",
                                times: ["04:00", "05:30", "12:10", "16:00", "18:50", "20:30"])
        let city = CityPrayerSchedule(
            id: grozny.id, name: grozny.name, timeZone: grozny.timeZoneID,
            coverageStatus: "partial", coverageStart: covered.date, coverageEnd: covered.date,
            releaseStatus: "test", source: source, days: [covered]
        )
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 1,
            completeCityCount: 0, partialCityCount: 1, cities: [city], sourceLabel: "РДУМ ЧО"
        )
        let table = ScheduleTablePrayerProvider(catalog: catalog)

        // День внутри покрытия — таблица.
        let inside = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27)))
        let fromTable = try XCTUnwrap(PrayerStore.preferredTimes(
            for: grozny, on: inside, table: table, calculated: CalculatedPrayerProvider()))
        XCTAssertTrue(fromTable.source.isVerifiedTable)

        // День вне покрытия — расчёт с другой подписью.
        let outside = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 10, day: 1)))
        let fallback = try XCTUnwrap(PrayerStore.preferredTimes(
            for: grozny, on: outside, table: table, calculated: CalculatedPrayerProvider()))
        XCTAssertFalse(fallback.source.isVerifiedTable,
                       "вне покрытия таблицы источник обязан перестать быть выверенным")
        XCTAssertNotEqual(fallback.source.label, fromTable.source.label,
                          "подпись источника обязана смениться вместе с ним")
    }

    /// Sajda и 1Muslim разрешены владельцем только для сверки: их данные
    /// не имеют права попасть в продукт как выверенная таблица.
    func testQAOnlySourcesAreNotUsableInProduct() {
        XCTAssertFalse(PrayerSource(name: "Sajda", url: "https://sajda.app",
                                    sha256: "x").isUsableInProduct)
        XCTAssertFalse(PrayerSource(name: "Календарь", url: "https://1muslim.pro/x",
                                    sha256: "x").isUsableInProduct)
        XCTAssertFalse(PrayerSource(name: " ", url: "https://x.ru", sha256: "x").isUsableInProduct,
                       "безымянный источник — не источник")
        XCTAssertFalse(PrayerSource(name: "ДУМ РТ", url: "", sha256: "x").isUsableInProduct,
                       "без ссылки на первоисточник таблица не прослеживается")
        XCTAssertFalse(PrayerSource(name: "ДУМ РТ", url: "https://dumrt.ru/x.xlsx",
                                    sha256: " ").isUsableInProduct,
                       "без хеша нельзя проверить, что данные не подменены")
        XCTAssertTrue(PrayerSource(name: "ЦДУМ России", url: "https://cdum.ru",
                                   sha256: "x").isUsableInProduct)
        // Причина отказа должна называть себя, а не сваливать всё в одну.
        XCTAssertEqual(PrayerSource(name: "ДУМ РТ", url: "", sha256: "x").rejectionReason,
                       "no-source-url")
        XCTAssertEqual(PrayerSource(name: "Sajda", url: "https://sajda.app",
                                    sha256: "x").rejectionReason, "qa-only-source")
        XCTAssertEqual(PrayerSource(name: " ", url: "https://x.ru",
                                    sha256: "x").rejectionReason, "no-name")
        XCTAssertEqual(PrayerSource(name: "ДУМ РТ", url: "https://dumrt.ru/x.xlsx",
                                    sha256: " ").rejectionReason, "no-source-hash")
    }

    /// Два годовых файла дают два города с одним названием: выбирать надо
    /// тот, чьё покрытие включает запрошенный день.
    func testOverlappingCatalogsPickCoveringYear() throws {
        func city(_ id: String, from: String, to: String, day: PrayerDay,
                  source: String) -> CityPrayerSchedule {
            CityPrayerSchedule(
                id: id, name: grozny.name, timeZone: grozny.timeZoneID,
                coverageStatus: "complete", coverageStart: from, coverageEnd: to,
                releaseStatus: "test",
                source: PrayerSource(name: source, url: "https://example.org/schedule.xlsx", sha256: "fixture"),
                days: [day])
        }
        let old = city("y2026", from: "2026-01-01", to: "2026-12-31",
                       day: PrayerDay(date: "2026-08-27",
                                      times: ["01:11", "02:22", "03:33", "04:44", "05:55", "06:56"]),
                       source: "ЦДУМ России")
        let new = city("y2027", from: "2027-01-01", to: "2027-12-31",
                       day: PrayerDay(date: "2027-08-27",
                                      times: ["01:12", "02:23", "03:34", "04:45", "05:56", "06:57"]),
                       source: "ДУМ РТ")
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2027, cityCount: 2,
            completeCityCount: 2, partialCityCount: 0,
            cities: [old, new], sourceLabel: nil)

        let in2026 = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27)))
        let in2027 = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2027, month: 8, day: 27)))
        XCTAssertEqual(catalog.city(named: grozny.name, on: in2026)?.id, "y2026")
        XCTAssertEqual(catalog.city(named: grozny.name, on: in2027)?.id, "y2027")
        // Без даты выбирать не из чего — отказ вместо угадывания.
        XCTAssertNil(catalog.city(named: grozny.name))
    }

    func testUserCatalogOverridesOnlyDatesItCovers() throws {
        let directory = try TestFiles.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func writeCatalog(_ name: String, year: Int, fajr: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            let city: [String: Any] = [
                "id": "grozny", "name": "Грозный", "timeZone": "Europe/Moscow",
                "coverageStatus": "complete", "coverageStart": "\(year)-01-01",
                "coverageEnd": "\(year)-12-31", "releaseStatus": "test",
                "source": ["name": name, "url": "https://example.org/calendar", "sha256": "fixture"],
                "days": [["date": "\(year)-08-27",
                          "times": [fajr, "05:30", "12:30", "16:00", "18:30", "20:00"]]],
            ]
            try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "year": year, "cityCount": 1,
                "completeCityCount": 1, "partialCityCount": 0, "cities": [city],
            ]).write(to: url)
            return url
        }
        let bundled = try writeCatalog("bundled.json", year: 2026, fajr: "04:00")
        let nextYear = try writeCatalog("next-year.json", year: 2027, fajr: "04:10")
        let override = try writeCatalog("override.json", year: 2026, fajr: "04:20")
        let today = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27)))
        let future = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2027, month: 8, day: 27)))

        let table = try XCTUnwrap(ScheduleTablePrayerProvider.userProvided(
            bundledURLs: [bundled], userURLs: [nextYear]))
        XCTAssertEqual(table.times(on: today, city: grozny)?.source.label, "bundled.json")
        XCTAssertEqual(table.times(on: future, city: grozny)?.source.label, "next-year.json")

        let overridden = try XCTUnwrap(ScheduleTablePrayerProvider.userProvided(
            bundledURLs: [bundled], userURLs: [nextYear, override]))
        XCTAssertEqual(overridden.times(on: today, city: grozny)?.fajr.map(grozny.formattedTime), "04:20")
        XCTAssertEqual(overridden.times(on: future, city: grozny)?.source.label, "next-year.json")
    }

    /// Годовые файлы переиспользуют одни и те же идентификаторы: провайдер
    /// обязан взять день ИЗ ВЫБРАННОГО снимка, а не из первого с таким id.
    func testCollidingIdentifiersDoNotLeakDaysAcrossSnapshots() throws {
        func snapshot(from: String, to: String, day: PrayerDay,
                      source: String) -> CityPrayerSchedule {
            CityPrayerSchedule(
                id: "город", name: grozny.name, timeZone: grozny.timeZoneID,
                coverageStatus: "complete", coverageStart: from, coverageEnd: to,
                releaseStatus: "test",
                source: PrayerSource(name: source, url: "https://example.org/schedule.xlsx", sha256: "fixture"),
                days: [day])
        }
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2027, cityCount: 2,
            completeCityCount: 2, partialCityCount: 0,
            cities: [
                snapshot(from: "2026-01-01", to: "2026-12-31",
                         day: PrayerDay(date: "2026-08-27",
                                        times: ["01:11", "02:22", "03:33", "04:44", "05:55", "06:56"]),
                         source: "ЦДУМ России"),
                snapshot(from: "2027-01-01", to: "2027-12-31",
                         day: PrayerDay(date: "2027-08-27",
                                        times: ["07:11", "08:22", "09:33", "10:44", "11:55", "12:56"]),
                         source: "ДУМ РТ"),
            ],
            sourceLabel: nil)
        let provider = ScheduleTablePrayerProvider(catalog: catalog)

        let date2027 = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2027, month: 8, day: 27)))
        let times = try XCTUnwrap(provider.times(on: date2027, city: grozny))
        XCTAssertEqual(times.source.label, "ДУМ РТ")
        let hour = grozny.calendar.component(.hour, from: try XCTUnwrap(times.fajr))
        XCTAssertEqual(hour, 7, "взят день из снимка 2026 года")
    }

    /// Сводный каталог: у каждого города своя подпись. Общий ярлык не
    /// имеет права переименовать чужой муфтият.
    func testCitySourceWinsOverCatalogWideLabel() throws {
        let day = PrayerDay(date: "2026-08-27",
                            times: ["04:00", "05:30", "12:10", "16:00", "18:50", "20:30"])
        let city = CityPrayerSchedule(
            id: "город", name: grozny.name, timeZone: grozny.timeZoneID,
            coverageStatus: "complete", coverageStart: day.date, coverageEnd: day.date,
            releaseStatus: "test",
            source: PrayerSource(name: "ЦДУМ России", url: "https://example.org/schedule.xlsx", sha256: "fixture"),
            days: [day]
        )
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 1,
            completeCityCount: 1, partialCityCount: 0, cities: [city],
            sourceLabel: "ДУМ РТ"
        )
        let date = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 27)))
        let times = try XCTUnwrap(ScheduleTablePrayerProvider(catalog: catalog)
            .times(on: date, city: grozny))
        XCTAssertEqual(times.source.label, "ЦДУМ России",
                       "подпись обязана принадлежать источнику ГОРОДА")
    }

    /// Каталог приходит из чужого конвейера с кириллическими id, наши —
    /// латиницей: сопоставление идёт по нормализованному названию.
    func testCatalogMatchesCityByNameNotIdentifier() throws {
        let source = PrayerSource(name: "ДУМ РТ", url: "https://example.org/schedule.xlsx", sha256: "fixture")
        let day = PrayerDay(date: "2026-08-27",
                            times: ["01:11", "02:22", "03:33", "04:44", "05:55", "06:56"])
        let city = CityPrayerSchedule(
            id: "казань", name: "Казань", timeZone: grozny.timeZoneID,
            coverageStatus: "complete", coverageStart: day.date, coverageEnd: day.date,
            releaseStatus: "permissionRequired", source: source, days: [day]
        )
        let catalog = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 1,
            completeCityCount: 1, partialCityCount: 0, cities: [city], sourceLabel: "ДУМ РТ"
        )
        XCTAssertNotNil(catalog.city(named: "казань"), "регистр не должен мешать")
        XCTAssertNotNil(catalog.city(named: "Казань"))
        XCTAssertNil(catalog.city(named: "Москва"))
        // Одноимённые города — отказ, а не «первый попавшийся».
        let twin = CityPrayerSchedule(
            id: "казань-2", name: "Казань", timeZone: grozny.timeZoneID,
            coverageStatus: "complete", coverageStart: day.date, coverageEnd: day.date,
            releaseStatus: "permissionRequired", source: source, days: [day]
        )
        let ambiguous = PrayerCatalog(
            schemaVersion: 1, year: 2026, cityCount: 2,
            completeCityCount: 2, partialCityCount: 0,
            cities: [city, twin], sourceLabel: "ДУМ РТ"
        )
        XCTAssertNil(ambiguous.city(named: "Казань"),
                     "при неоднозначности каталог обязан отказаться, а не угадывать")
        XCTAssertEqual(PrayerCatalog.normalized("Набережные  Челны"), "набережные челны")
        XCTAssertEqual(PrayerCatalog.normalized("Ростов-на-Дону"),
                       PrayerCatalog.normalized("ростов на дону"))
    }

    /// Все записи поставляются целиком, без дублирующего системного звука.
    func testAdhanSoundIsBundledAndSelectable() {
        let bundle = Bundle(for: PrayerNotifications.self)
        // Каждый звук обязан лежать в бандле: иначе система молча
        // подставит стандартный, и пользователь не поймёт, почему выбор
        // ничего не изменил.
        for option in PrayerNotifications.Sound.allCases {
            guard let name = option.fileName else { continue }
            let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                 withExtension: (name as NSString).pathExtension)
            XCTAssertNotNil(url, "звук не попал в бандл: \(name)")
        }
        XCTAssertNil(PrayerNotifications.Sound.system.fileName,
                     "системный звук не должен ссылаться на файл")

        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: PrayerNotifications.soundStorageKey)
        defer {
            if let previous { defaults.set(previous, forKey: PrayerNotifications.soundStorageKey) }
            else { defaults.removeObject(forKey: PrayerNotifications.soundStorageKey) }
        }
        defaults.removeObject(forKey: PrayerNotifications.soundStorageKey)
        XCTAssertEqual(PrayerNotifications.sound, .system, "по умолчанию — системный звук")
        PrayerNotifications.setSound(.adhan2)
        XCTAssertEqual(PrayerNotifications.sound, .adhan2)
        let notificationDate = Date()
        let content = PrayerNotifications.content(
            kind: .fajr, at: notificationDate, city: grozny,
            source: PrayerTimesSource(label: "ДУМ ЧР", isVerifiedTable: true),
            mode: .notification)
        XCTAssertNil(content.sound, "плеер азана не должен дублироваться системным сигналом")
        XCTAssertEqual(content.subtitle, "Грозный")
        XCTAssertEqual(content.body, grozny.formattedTime(notificationDate))

        PrayerNotifications.setSound(.system)
        let reminder = PrayerNotifications.content(
            kind: .fajr, at: Date(), city: grozny,
            source: PrayerTimesSource(label: "Расчёт MWL", isVerifiedTable: false),
            mode: .reminder)
        XCTAssertEqual(reminder.subtitle, "Грозный")
        XCTAssertTrue(reminder.body.contains("Расчёт MWL"))
        XCTAssertTrue(reminder.title.contains("через"))
        XCTAssertNotNil(reminder.sound)

        // Защита от подмены азана двухсекундным сигналом.
        for option in PrayerNotifications.Sound.allCases where option.isAdhan {
            guard let name = option.fileName,
                  let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                       withExtension: (name as NSString).pathExtension),
                  let audio = try? AVAudioFile(forReading: url) else {
                return XCTFail("не прочитан звук \(option.rawValue)")
            }
            let seconds = Double(audio.length) / audio.fileFormat.sampleRate
            XCTAssertGreaterThan(seconds, 10, "\(option.rawValue) подозрительно короткий")
        }
    }

    /// «Напоминание заранее» сдвигает момент уведомления, «выключено»
    /// и прошедшее время — убирают.
    func testFireDateFollowsModeAndSkipsPast() {
        let defaults = UserDefaults.standard
        let key = PrayerNotifications.modeKey(for: .dhuhr)
        let previous = defaults.string(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let prayer = now.addingTimeInterval(3600)

        defaults.set(PrayerNotifications.Mode.notification.rawValue, forKey: key)
        XCTAssertEqual(PrayerNotifications.fireDate(kind: .dhuhr, at: prayer, now: now), prayer)
        XCTAssertNil(PrayerNotifications.fireDate(kind: .dhuhr, at: now, now: now),
                     "наступивший момент уже не планируется")

        defaults.set(PrayerNotifications.Mode.reminder.rawValue, forKey: key)
        XCTAssertEqual(PrayerNotifications.fireDate(kind: .dhuhr, at: prayer, now: now),
                       prayer.addingTimeInterval(-Double(PrayerNotifications.reminderMinutes) * 60))

        defaults.set(PrayerNotifications.Mode.off.rawValue, forKey: key)
        XCTAssertNil(PrayerNotifications.fireDate(kind: .dhuhr, at: prayer, now: now))
    }

    /// Прослушивание: у системного звука файла нет, играть нечего —
    /// подменять его похожим значило бы врать о том, что услышит
    /// пользователь. Остальные обязаны запускаться и смолкать по команде.
    @MainActor
    func testSoundPreviewPlaysFilesAndIgnoresSystem() {
        let preview = PrayerSoundPreview()
        preview.play(.system)
        XCTAssertNil(preview.playing, "у системного звука нечего проигрывать")

        preview.play(.chime)
        XCTAssertEqual(preview.playing, .chime)
        preview.toggle(.chime)
        XCTAssertNil(preview.playing, "повторное нажатие обязано останавливать")

        preview.play(.adhan1)
        XCTAssertEqual(preview.playing, .adhan1)
        preview.toggle(.warm)
        XCTAssertEqual(preview.playing, .warm, "другой звук — начинаем заново")
        preview.stop()
        XCTAssertNil(preview.playing)
    }

    func testScheduledSoundSkipsSuppressedDeniedAndMissedEvents() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func allowed(_ offset: TimeInterval, suppressed: Bool = false,
                     authorization: UNAuthorizationStatus = .authorized,
                     setting: UNNotificationSetting = .enabled) -> Bool {
            PrayerNotifications.shouldPlaySound(
                at: date, now: date.addingTimeInterval(offset), suppressed: suppressed,
                authorization: authorization, soundSetting: setting)
        }
        XCTAssertTrue(allowed(0))
        XCTAssertTrue(allowed(1))
        XCTAssertTrue(allowed(-0.05), "коррекция часов не должна отменять единственный callback таймера")
        XCTAssertTrue(allowed(-0.001))
        XCTAssertFalse(allowed(-1))
        XCTAssertFalse(allowed(5), "после сна пропущенное аудио не запускается")
        XCTAssertFalse(allowed(0, suppressed: true))
        XCTAssertFalse(allowed(0, authorization: .denied))
        XCTAssertFalse(allowed(0, setting: .disabled))
    }

    func testAllAdhansFinishNaturallyAndPausePreservesTheRemainingAudio() async throws {
        let preview = PrayerSoundPreview()
        defer { preview.stop() }
        for sound in PrayerNotifications.Sound.allCases where sound.isAdhan {
            preview.play(sound)
            let audio = try XCTUnwrap(preview.player, sound.title)
            audio.volume = 0
            try await Task.sleep(for: .milliseconds(200))
            preview.pause()
            let position = audio.currentTime
            XCTAssertGreaterThan(position, 0, sound.title)
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(audio.currentTime, position, accuracy: 0.05, sound.title)
            XCTAssertEqual(preview.playing, sound)
            preview.resume()
            try await Task.sleep(for: .seconds(audio.duration - position - 0.5))
            XCTAssertTrue(audio.isPlaying, "\(sound.title) не должен обрываться до конца файла")
            XCTAssertGreaterThan(audio.currentTime, audio.duration - 1, sound.title)
            XCTAssertEqual(preview.playing, sound)
            try await Task.sleep(for: .seconds(1))
            XCTAssertNil(preview.playing, "\(sound.title): состояние сбрасывается после конца файла")
            print("\(sound.title): \(audio.duration) seconds, natural playback completion verified")
        }
    }

    /// Каталог, который реально поставляется с приложением: города
    /// Кавказа обязаны разрешаться в ТАБЛИЦУ, а не в расчёт. Тест ходит
    /// по настоящему файлу ресурсов — подделка фикстурой не показала бы,
    /// что данные доехали до бандла.
    func testBundledCatalogResolvesCaucasusCitiesToTables() throws {
        let provider = try XCTUnwrap(ScheduleTablePrayerProvider.userProvided(userURLs: []),
                                     "каталог не найден в бандле")
        // Подпись обязана называть ФАКТИЧЕСКИЙ источник записи. Казань и
        // Грозный — таблицы муфтиятов; пять городов заменены по решению
        // владельца файлами govzalla, и подпись это показывает, а не
        // выдаёт их за ЦДУМ.
        let expected = [
            ("Грозный", "ДУМ ЧР"),
            ("Казань", "ДУМ РТ"),
            ("Махачкала", "Муфтият РД"),
            ("Нальчик", "ДУМ КБР"),
            ("Москва", "govzalla.com"),
            ("Волгоград", "govzalla.com"),
        ]
        let date = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 28)))
        for (name, label) in expected {
            // Часовой пояс берём из НАШЕГО списка городов: таблица
            // отдаётся только при совпадении пояса, и подставлять всем
            // московский значило бы проверять не то.
            let zone = try XCTUnwrap(
                PrayerStore.cities.first { $0.name == name }?.timeZoneID,
                "\(name): нет в списке городов")
            let city = PrayerCity(id: "test:" + name, name: name,
                                  latitude: nil, longitude: nil,
                                  timeZoneID: zone, madhab: .shafi,
                                  method: .muslimWorldLeague)
            let times = try XCTUnwrap(provider.times(on: date, city: city),
                                      "\(name): таблицы нет")
            XCTAssertTrue(times.source.isVerifiedTable)
            XCTAssertEqual(times.source.label, label)
            XCTAssertNotNil(times.fajr)
            XCTAssertNotNil(times.isha)
        }
    }

    /// ДУМ ЧР публикует одно расписание на республику: города Чечни
    /// обязаны показывать таблицу Грозного, с честной оговоркой об этом.
    func testChechenCitiesUseGroznySchedule() throws {
        let provider = try XCTUnwrap(ScheduleTablePrayerProvider.userProvided(userURLs: []),
                                     "каталог не найден в бандле")
        let date = try XCTUnwrap(grozny.calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 28)))
        let reference = try XCTUnwrap(provider.times(on: date, city: grozny))
        for name in ["Гудермес", "Урус-Мартан", "Шали", "Аргун"] {
            let city = try XCTUnwrap(PrayerStore.cities.first { $0.name == name },
                                     "\(name): нет в списке городов")
            let times = try XCTUnwrap(provider.times(on: date, city: city),
                                      "\(name): таблицы нет")
            XCTAssertEqual(times.fajr, reference.fajr, name)
            XCTAssertEqual(times.isha, reference.isha, name)
            XCTAssertEqual(times.source.label, "ДУМ ЧР")
            XCTAssertNotNil(times.source.caveat, name)
        }
        // У самого Грозного оговорки нет — это его собственная таблица.
        XCTAssertNil(reference.source.caveat)
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

    /// Все намазы выключены — это осознанный выбор, а не сбой: старые
    /// запросы обязаны сниматься, иначе выключенные уведомления
    /// продолжали бы приходить.
    func testAllPrayersOffIsNotTreatedAsFailure() {
        let empty = PrayerNotifications.Outcome(scheduled: 0, failed: 0)
        XCTAssertTrue(empty.isComplete, "пустое расписание без ошибок — не сбой")
        let broken = PrayerNotifications.Outcome(scheduled: 0, failed: 3)
        XCTAssertFalse(broken.isComplete, "неудачные постановки обязаны быть видимы")
    }
}
