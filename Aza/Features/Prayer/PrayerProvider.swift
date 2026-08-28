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
    /// Координаты нужны ТОЛЬКО для расчёта. У городов, пришедших из
    /// официального каталога, их может не быть: выдумывать координаты
    /// населённого пункта ради красивого запасного пути — значит
    /// показывать пользователю выдуманное время намаза.
    let latitude: Double?
    let longitude: Double?
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

    func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = timeZone
        return formatter.string(from: date)
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
        // Без координат считать нечего — честнее не показать ничего.
        guard let latitude = city.latitude, let longitude = city.longitude else {
            return nil
        }
        let coordinates = Coordinates(latitude: latitude, longitude: longitude)
        let components = city.calendar.dateComponents([.year, .month, .day], from: date)

        var params = city.method.params
        params.madhab = city.madhab
        params.highLatitudeRule = .recommended(for: coordinates)

        guard let times = PrayerTimes(coordinates: coordinates,
                                      date: components,
                                      calculationParameters: params) else {
            return nil
        }

        let isHighLatitude = abs(latitude) > Self.highLatitudeThreshold
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

/// Пустой класс, чтобы найти бандл с ресурсами: `Bundle(for:)` требует
/// класс, а провайдер — структура.
private final class CatalogBundleMarker {}

/// Готовая таблица (ДУМ ЧР, ДУМ РТ и т.п.) — приоритетный источник.
/// Каталог поставляется с приложением (Aza/Resources), пользователь может
/// добавить свои файлы в Application Support/Aza/prayer-schedules.
/// Источники и условия — docs/PLAN-prayer-schedules.md.
struct ScheduleTablePrayerProvider: PrayerTimesProvider {
    let catalog: PrayerCatalog

    private static let maximumCatalogBytes = 10 * 1024 * 1024

    /// Каталог приложения плюс всё, что пользователь положил себе сам.
    ///
    /// Свои файлы читаются ПОСЛЕ поставляемого: при совпадении названий
    /// побеждает тот, чьё покрытие включает нужный день, а если различить
    /// нельзя — отказ. Проверка происхождения одна и та же для обоих:
    /// поставляемый каталог не получает поблажек.
    static func userProvided() -> ScheduleTablePrayerProvider? {
        let directory = ClipboardStore.defaultStorageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("prayer-schedules", isDirectory: true)
        let bundled = bundledCatalogURLs()
        let userFiles = ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let files = bundled + userFiles
        // Файлов может быть несколько (годовые каталоги живут рядом), и
        // брать «первый попавшийся» нельзя: подходящий год мог оказаться
        // вторым. Собираем города из ВСЕХ пригодных файлов — какой
        // конкретно подходит запрошенному дню, решает уже поиск по
        // покрытию.
        // Поставляемые и пользовательские города копятся раздельно:
        // свой файл перекрывает ТОЛЬКО поставляемый каталог (копия
        // каталога рядом давала неразличимые дубли), но не другие свои —
        // годовые файлы одного города различаются покрытием, и какой
        // подходит запрошенному дню, решает поиск по покрытию.
        var bundledCities: [CityPrayerSchedule] = []
        var userCities: [CityPrayerSchedule] = []
        var year = 0
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = boundedData(from: file),
                  let catalog = try? JSONDecoder().decode(PrayerCatalog.self, from: data),
                  !catalog.cities.isEmpty else { continue }
            // Источник, разрешённый только для сверки, в продукт не идёт:
            // иначе его времена показались бы как выверенная таблица.
            let reasons = Set(catalog.cities.compactMap(\.source.rejectionReason))
            guard reasons.isEmpty else {
                azaDebugLog("Aza: prayer catalog rejected file=\(file.lastPathComponent) "
                            + "reasons=\(reasons.sorted().joined(separator: ","))")
                continue
            }
            if !bundled.contains(file) {
                let names = Set(catalog.cities.map { PrayerCatalog.normalized($0.name) })
                bundledCities.removeAll { names.contains(PrayerCatalog.normalized($0.name)) }
                // Точный дубль (то же имя И то же покрытие — копия файла)
                // заменяется; другой год того же города остаётся жить.
                for city in catalog.cities {
                    userCities.removeAll {
                        PrayerCatalog.normalized($0.name) == PrayerCatalog.normalized(city.name)
                            && $0.coverageStart == city.coverageStart
                            && $0.coverageEnd == city.coverageEnd
                    }
                }
                userCities.append(contentsOf: catalog.cities.map {
                    var city = $0
                    city.userProvided = true
                    return city
                })
            } else {
                bundledCities.append(contentsOf: catalog.cities)
            }
            year = max(year, catalog.year)
        }
        let cities = bundledCities + userCities
        guard !cities.isEmpty else { return nil }
        // Общая подпись намеренно nil: файлы бывают сводными, и подпись
        // берётся у КАЖДОГО города своя.
        return ScheduleTablePrayerProvider(catalog: PrayerCatalog(
            schemaVersion: 1, year: year, cityCount: cities.count,
            completeCityCount: cities.filter(\.isComplete).count,
            partialCityCount: cities.filter { !$0.isComplete }.count,
            cities: cities, sourceLabel: nil
        ))
    }

    /// Каталоги, поставляемые с приложением. Их несколько не бывает, но
    /// список — чтобы годовые файлы можно было добавлять, ничего не меняя.
    private static func bundledCatalogURLs() -> [URL] {
        // Ищем в бандле, где лежит наш код, а не в Bundle.main: под
        // тестами main — это раннер, и поставляемый каталог не виден
        // вовсе. Тест на настоящем каталоге этим и падал.
        let bundle = Bundle(for: CatalogBundleMarker.self)
        return (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("prayer-schedules") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// ДУМ ЧР выпускает ОДНО расписание на всю республику, поэтому города
    /// Чечни показывают таблицу Грозного — это не подмена, а факт источника.
    private static let tableAliases: [String: String] = [
        "гудермес": "Грозный",
        "урус мартан": "Грозный",
        "шали": "Грозный",
        "аргун": "Грозный",
    ]

    func times(on date: Date, city: PrayerCity) -> DayPrayerTimes? {
        // Ищем по НАЗВАНИЮ: идентификаторы каталога приходят из чужого
        // конвейера (кириллица «казань») и с нашими не совпадают.
        // Часовой пояс обязан совпасть — иначе это другой город.
        let lookupName = Self.tableAliases[PrayerCatalog.normalized(city.name)] ?? city.name
        guard let tableCity = catalog.city(named: lookupName, on: date),
              tableCity.timeZone == city.timeZoneID else { return nil }
        let occurrences = catalog.prayers(tableCity, on: date)
        guard occurrences.count == PrayerKind.allCases.count,
              occurrences.map(\.date) == occurrences.map(\.date).sorted() else { return nil }
        // Источник ГОРОДА главнее общей подписи каталога. Каталог бывает
        // сводным (ДУМ РТ + ЦДУМ + РДУМ ЧО в одном файле), и общий ярлык
        // подписал бы времена одного муфтията именем другого — ровно то
        // смешивание источников, которое запрещено.
        let label = nonEmpty(tableCity.source.shortName)
            ?? nonEmpty(catalog.sourceLabel ?? "")
            ?? ""
        guard !label.isEmpty else { return nil }
        // §4.3: подпись честная — пользователь видит и что расписание
        // республиканское (по Грозному), и что файл добавлен вручную:
        // «выверенность» такого файла — на совести добавившего, проверка
        // источника здесь — прослеживаемость, не подлинность.
        let caveats = [
            tableCity.userProvided ? "Расписание из файла, добавленного вручную" : nil,
            lookupName == city.name ? nil : "Единое расписание \(label) по времени Грозного",
        ].compactMap { $0 }
        var result = DayPrayerTimes(
            source: PrayerTimesSource(
                label: label, isVerifiedTable: true,
                caveat: caveats.isEmpty ? nil : caveats.joined(separator: "; ")
            )
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

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
