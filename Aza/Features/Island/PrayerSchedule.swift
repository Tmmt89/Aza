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
    /// Хеш ПЕРВОИСТОЧНИКА (PDF/страницы муфтията) — метаданные для
    /// прослеживаемости, НЕ криптографическая проверка: ни с чем не
    /// сверяется. «Выверенность» таблицы означает «источник назван и
    /// прослеживается», а не «подлинность доказана» — файлы кладёт сам
    /// пользователь в свою папку, аутентификация здесь ничего не защитит.
    let sha256: String

    var shortName: String {
        switch name {
        case "ДУМ Республики Татарстан": "ДУМ РТ"
        case "РДУМ Челябинской области": "РДУМ ЧО"
        case "ДУМ Кабардино-Балкарской Республики": "ДУМ КБР"
        case "Муфтият Республики Дагестан": "Муфтият РД"
        default: name
        }
    }

    /// Агрегаторы, которые владелец разрешил использовать ТОЛЬКО для
    /// сверки, но не как источник времён в продукте. Их данные не должны
    /// попасть в интерфейс под видом выверенного расписания — даже если
    /// кто-то положит такой файл в папку расписаний вручную.
    private static let qaOnlyOrigins = ["sajda", "1muslim", "muslim.by"]

    /// Годится ли источник для продукта.
    ///
    /// Списка «правильных» организаций здесь нет и быть не может: правило
    /// владельца разрешает расписание любой мечети, а решать, какая мечеть
    /// легитимна, — не наше дело. Вместо этого требуем ПРОСЛЕЖИВАЕМОСТЬ:
    /// таблица считается выверенной, только если умеет показать, откуда
    /// взята — имя, ссылка на первоисточник и его хеш. Плюс прямой запрет
    /// на два агрегатора, которые владелец разрешил только для сверки.
    var isUsableInProduct: Bool { rejectionReason == nil }

    /// Почему источник непригоден — для диагностики. Одна причина на все
    /// отказы врала бы в логе: «qa-only» на самом деле мог означать
    /// отсутствующий хеш.
    var rejectionReason: String? {
        func filled(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard filled(name) else { return "no-name" }
        guard filled(url) else { return "no-source-url" }
        guard filled(sha256) else { return "no-source-hash" }
        let haystack = (name + " " + url).lowercased()
        return Self.qaOnlyOrigins.contains { haystack.contains($0) } ? "qa-only-source" : nil
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
    /// Город пришёл из файла, добавленного пользователем, а не из
    /// поставляемого каталога. В JSON не кодируется — проставляется при
    /// загрузке; интерфейс помечает такие времена честной оговоркой.
    var userProvided = false

    private enum CodingKeys: String, CodingKey {
        case id, name, timeZone, coverageStatus, coverageStart,
             coverageEnd, releaseStatus, source, days
    }

    var isComplete: Bool { coverageStatus == "complete" }

    /// Попадает ли день в объявленное покрытие. Даты ISO сравниваются как
    /// строки — порядок у них совпадает с календарным. День берётся в
    /// часовом поясе города, а не системном.
    func covers(_ date: Date) -> Bool {
        guard let timeZone = TimeZone(identifier: timeZone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let key = String(format: "%04d-%02d-%02d",
                         parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return key >= coverageStart && key <= coverageEnd
    }
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

    /// Первые две минуты намаза. Восход — граница времени, не молитва.
    static func current(in occurrences: [PrayerOccurrence], at now: Date) -> PrayerOccurrence? {
        occurrences.last {
            $0.kind != .sunrise && (0..<120).contains(now.timeIntervalSince($0.date))
        }
    }
}

struct PrayerCatalog: Decodable {
    /// Поддерживаемая версия схемы: файлы новее не читаем — молча выбросить
    /// незнакомые поля значит показать не те времена под видом выверенных.
    static let supportedSchemaVersion = 1

    let schemaVersion: Int
    let year: Int
    let cityCount: Int
    let completeCityCount: Int
    let partialCityCount: Int
    let cities: [CityPrayerSchedule]
    /// Кто выпустил таблицу («ДУМ ЧР»): подпись обязана быть в интерфейсе
    /// (§4.3). Опционально — старые файлы без поля читаются как прежде.
    let sourceLabel: String?
    /// Порядок значений в times, как его декларирует сам файл. Раньше поле
    /// игнорировалось, а времена зиповались по зашитому порядку enum —
    /// файл с другим порядком показал бы времена под чужими именами.
    var prayers: [String]? = nil

    /// Заявленный порядок совпадает с нашим (или не заявлен — тогда
    /// действует контракт схемы v1: Fajr…Isha).
    var declaresSupportedOrder: Bool {
        guard let prayers else { return true }
        return prayers == PrayerKind.allCases.map(\.rawValue)
    }

    // Каталога в бандле нет и быть не должно: расписания приходят из
    // Application Support и проходят проверку происхождения в
    // ScheduleTablePrayerProvider.userProvided(). Прежний `bundled`
    // читал бы файл из бандла мимо этой проверки — удалён.

    // Поиска по id здесь намеренно нет: после слияния годовых файлов
    // идентификаторы перестали быть уникальными, и «первый с таким id»
    // возвращал день из чужого снимка.

    /// Поиск по НАЗВАНИЮ: идентификаторы каталога и приложения живут
    /// независимо (в каталоге — кириллица «казань», в списке городов —
    /// латиница «kazan»), поэтому сопоставляем по нормализованному имени.
    /// Одноимённых городов быть не должно (в текущем каталоге их нет), но
    /// каталог приходит извне: при совпадении имён молча взять первый —
    /// значит показать пользователю расписание ЧУЖОГО города. Лучше
    /// честно отказаться и уйти в расчёт.
    func city(named name: String, on date: Date? = nil) -> CityPrayerSchedule? {
        let target = Self.normalized(name)
        var matches = cities.filter { Self.normalized($0.name) == target }
        if let date {
            // Покрытие обязано включать день и для ЕДИНСТВЕННОГО совпадения:
            // случайная строка за пределами заявленного покрытия иначе
            // показывалась бы как выверенная таблица вместо отказа.
            matches = matches.filter { $0.covers(date) }
            let userMatches = matches.filter(\.userProvided)
            if !userMatches.isEmpty { matches = userMatches }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Нижний регистр, «ё» → «е», дефисы и пробелы — к одному виду:
    /// «Набережные Челны», «набережные-челны» — один город.
    static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Принимает САМ город, а не его идентификатор: после слияния годовых
    /// файлов идентификаторы перестали быть уникальными, и повторный поиск
    /// по id вернул бы день из другого снимка под подписью выбранного.
    func prayers(_ city: CityPrayerSchedule, on date: Date) -> [PrayerOccurrence] {
        guard let calendar = calendar(for: city) else { return [] }
        let key = dateKey(date, calendar: calendar)
        let days = city.days.filter { $0.date == key }
        guard days.count == 1, let day = days.first,
              // Ровно шесть значений: zip молча отбросил бы лишние, и строка
              // с седьмым значением сошла бы за выверенную таблицу.
              day.times.count == PrayerKind.allCases.count else {
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
