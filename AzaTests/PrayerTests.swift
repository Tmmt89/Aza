import Adhan
import AVFoundation
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

    /// Азан звучит ЧЕРЕЗ систему уведомлений — только так соблюдаются
    /// Focus и «Не беспокоить». Файл обязан быть в бандле, иначе система
    /// молча подставит стандартный звук.
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

        // Азаны обязаны укладываться в системный предел уведомления,
        // иначе запись оборвётся на полуслове.
        for option in PrayerNotifications.Sound.allCases where option.isAdhan {
            guard let name = option.fileName,
                  let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                       withExtension: (name as NSString).pathExtension),
                  let audio = try? AVAudioFile(forReading: url) else {
                return XCTFail("не прочитан звук \(option.rawValue)")
            }
            let seconds = Double(audio.length) / audio.fileFormat.sampleRate
            XCTAssertLessThanOrEqual(seconds, 30, "\(option.rawValue) длиннее предела: \(seconds) с")
            XCTAssertGreaterThan(seconds, 1, "\(option.rawValue) подозрительно короткий")
        }
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

    /// Каталог, который реально поставляется с приложением: города
    /// Кавказа обязаны разрешаться в ТАБЛИЦУ, а не в расчёт. Тест ходит
    /// по настоящему файлу ресурсов — подделка фикстурой не показала бы,
    /// что данные доехали до бандла.
    func testBundledCatalogResolvesCaucasusCitiesToTables() throws {
        let provider = try XCTUnwrap(ScheduleTablePrayerProvider.userProvided(),
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
        let provider = try XCTUnwrap(ScheduleTablePrayerProvider.userProvided(),
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
