import AVFoundation
import Combine
import Foundation
import UserNotifications

/// Уведомления о намазе (§4.4).
///
/// Звуки поставляются с приложением: четыре азана и три коротких
/// синтезированных сигнала. Файлы играет собственный плеер до конца:
/// usernoted может заменить выбранную запись коротким системным звуком.
@MainActor
class PrayerNotifications: NSObject, UNUserNotificationCenterDelegate {
    /// Пауза действует и на уже начатую пересборку очереди.
    var isSuppressedForDictation = false {
        didSet {
            if isSuppressedForDictation { playback.pause() }
            else { playback.resume() }
        }
    }

    private let playback = PrayerSoundPreview()
    private var soundTimers: [Timer] = []
    private var soundScheduleID = UUID()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        isSuppressedForDictation ? [] : [.banner, .sound, .list]
    }

    /// Чем звучит уведомление. Отделено от режима: «когда сработает» и
    /// «что прозвучит» — разные вопросы, и складывать их в один
    /// перечислитель значит плодить его комбинациями.
    enum Sound: String, CaseIterable {
        case system
        case adhan1
        case adhan2
        case adhan3
        case adhan4
        case chime
        case twoTone
        case warm

        var title: String {
            switch self {
            case .system: "Системный"
            case .adhan1: "Азан 1"
            case .adhan2: "Азан 2"
            case .adhan3: "Азан 3"
            case .adhan4: "Азан 4"
            case .chime: "Колокольчик"
            case .twoTone: "Две ноты"
            case .warm: "Тёплый тон"
            }
        }

        /// Имя файла в бандле; nil — играет системный звук.
        var fileName: String? {
            switch self {
            case .system: nil
            case .adhan1: "adhan-1.caf"
            case .adhan2: "adhan-2.caf"
            case .adhan3: "adhan-3.caf"
            case .adhan4: "adhan-4.caf"
            case .chime: "tone-chime.caf"
            case .twoTone: "tone-twotone.caf"
            case .warm: "tone-warm.caf"
            }
        }

        var isAdhan: Bool {
            switch self {
            case .adhan1, .adhan2, .adhan3, .adhan4: true
            default: false
            }
        }
    }

    static let soundStorageKey = "PrayerNotificationSound"

    static var sound: Sound {
        guard let raw = UserDefaults.standard.string(forKey: soundStorageKey),
              let value = Sound(rawValue: raw) else { return .system }
        return value
    }

    static func setSound(_ value: Sound) {
        UserDefaults.standard.set(value.rawValue, forKey: soundStorageKey)
    }

    enum Mode: String, CaseIterable {
        case off
        case notification
        case reminder

        var title: String {
            switch self {
            case .off: "Выключено"
            case .notification: "Уведомление"
            case .reminder: "Напоминание заранее"
            }
        }
    }

    /// Отдельный ключ на намаз: настройки независимы, атомарность не
    /// нужна, а добавление новых режимов не потребует миграции формата.
    static func modeKey(for kind: PrayerKind) -> String {
        "PrayerNotificationMode.\(kind.rawValue)"
    }
    static let reminderMinutesKey = "PrayerReminderMinutes"

    static func mode(for kind: PrayerKind) -> Mode {
        // Восход — не намаз, по умолчанию молчит.
        let fallback: Mode = kind == .sunrise ? .off : .notification
        guard let raw = UserDefaults.standard.string(forKey: modeKey(for: kind)),
              let mode = Mode(rawValue: raw) else { return fallback }
        return mode
    }

    /// Хотя бы один намаз реально уведомляется. Когда всё выключено,
    /// пустой план — норма, а не «расписание неполное».
    static var anyModeEnabled: Bool {
        PrayerKind.allCases.contains { mode(for: $0) != .off }
    }

    static var reminderMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: reminderMinutesKey)
        return stored > 0 ? stored : 10
    }

    /// Горизонт планирования: неделя. Меньше — и уведомления пропадут,
    /// если Aza несколько дней не запускалась.
    static let horizonDays = 7

    private lazy var center: UNUserNotificationCenter = {
        let center = UNUserNotificationCenter.current()
        // Делегат нужен и для баннера, когда Aza активна.
        center.delegate = self
        return center
    }()

    /// Разрешение спрашиваем только по явному включению (§9: ни одно
    /// разрешение не обязательно).
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Текущий статус разрешения: center.add() принимает запросы и без
    /// него, и в момент намаза система молча их выбрасывает — расписание
    /// «стоит», а звука нет. Проверяется после каждого планирования.
    func authorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        azaDebugLog("Aza: notif settings auth=\(settings.authorizationStatus.rawValue) "
            + "alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) "
            + "style=\(settings.alertStyle.rawValue)")
        return settings.authorizationStatus
    }

    /// Пересобирает расписание уведомлений: снимает ВСЁ, потом ставит
    /// заново. Точечная чистка по идентификаторам не работает: usernoted
    /// может держать запись, которую pendingNotificationRequests не
    /// возвращает (31.08–02.09 призрак с временами MWL пережил все
    /// пересборки и дублировал уведомления), а add() с тем же id такую
    /// запись не заменяет. removeAllPendingNotificationRequests —
    /// единственный вызов, который бьёт и по невидимым записям. Окно
    /// «снято, но ещё не поставлено» — миллисекунды; убийство приложения
    /// в этом окне лечится пересборкой при следующем запуске.
    /// Итог планирования — чтобы интерфейс мог честно сказать, что
    /// расписание неполное. На уведомления о намазе полагаются каждый
    /// день, поэтому молчаливый сбой недопустим.
    struct Outcome {
        let scheduled: Int
        let failed: Int
        var isComplete: Bool { failed == 0 }
    }

    @discardableResult
    func reschedule(days: [(date: Date, times: DayPrayerTimes)],
                    city: PrayerCity,
                    now: Date = .now) async -> Outcome {
        guard !isSuppressedForDictation else { return Outcome(scheduled: 0, failed: 0) }
        // Запросы собираются ДО чистки, чтобы очередь пустовала минимум.
        var requests: [(request: UNNotificationRequest, date: Date)] = []
        for day in days {
            for occurrence in day.times.occurrences {
                guard let fireDate = Self.fireDate(kind: occurrence.kind, at: occurrence.date,
                                                   now: now) else { continue }
                let trigger = Self.trigger(for: fireDate, city: city)
                guard let soundDate = city.calendar.date(from: trigger.dateComponents) else { continue }
                requests.append((UNNotificationRequest(
                    identifier: Self.identifier(city: city, kind: occurrence.kind,
                                                date: occurrence.date),
                    content: Self.content(kind: occurrence.kind, at: occurrence.date,
                                          city: city, source: day.times.source,
                                          mode: Self.mode(for: occurrence.kind)),
                    trigger: trigger
                ), soundDate))
            }
        }

        clearSoundSchedule()
        let selectedSound = Self.sound
        center.removeAllPendingNotificationRequests()

        var scheduled = 0
        var failed = 0
        for (request, date) in requests {
            guard !isSuppressedForDictation else { break }
            do {
                try await center.add(request)
                scheduled += 1
                if !isSuppressedForDictation {
                    scheduleSound(selectedSound, at: date)
                }
            } catch {
                failed += 1
                azaDebugLog("Aza: prayer notification add failed")
            }
        }
        return Outcome(scheduled: scheduled, failed: failed)
    }

    /// Сначала завершается последний center.add, затем очередь снимается.
    /// Чтение после снятия подтверждает, что запись можно начать без звука
    /// из оставшегося pending-запроса. Настройки и разрешения не меняются.
    func pause(after pendingWork: Task<Void, Never>?) async -> Bool {
        await Self.pause(after: pendingWork, cancel: { self.cancelAll(preservingPlayback: true) }, pendingEmpty: {
            await self.center.pendingNotificationRequests().isEmpty
        })
    }

    /// Граница usernoted передаётся замыканиями, чтобы порядок барьера
    /// проверялся без системного центра и изменения очереди пользователя.
    static func pause(after pendingWork: Task<Void, Never>?,
                      cancel: () -> Void, pendingEmpty: () async -> Bool) async -> Bool {
        await pendingWork?.value
        cancel()
        return await pendingEmpty()
    }

    /// Диагностика Live QA: сколько уведомлений реально стоит в очереди
    /// и когда сработает ближайшее.
    func logPending() async {
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
        let next = pending
            .compactMap { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() }
            .min()
        let formatter = ISO8601DateFormatter()
        azaDebugLog("Aza: prayer notifications pending=\(pending.count) next=\(next.map(formatter.string(from:)) ?? "-")")
        // Доставленные — ground truth: запрос, ушедший из pending, мог быть
        // и показан, и молча выброшен; различить можно только здесь.
        let delivered = await center.deliveredNotifications()
            .filter { $0.request.identifier.hasPrefix(Self.identifierPrefix) }
            .map { "\($0.request.identifier)@\(formatter.string(from: $0.date))" }
        azaDebugLog("Aza: prayer notifications delivered=[\(delivered.joined(separator: ", "))]")
    }

    /// Aza не планирует никаких уведомлений, кроме намаза, поэтому «всё» —
    /// это и есть намаз. Снятие по идентификаторам не годится: невидимые
    /// для pendingNotificationRequests записи оно не достаёт (см.
    /// reschedule).
    func cancelAll(preservingPlayback: Bool = false) {
        clearSoundSchedule()
        // Диктовка приостанавливает уже начатую запись, а не обрезает её.
        if !preservingPlayback { playback.stop() }
        center.removeAllPendingNotificationRequests()
    }

    private func clearSoundSchedule() {
        soundScheduleID = UUID()
        soundTimers.forEach { $0.invalidate() }
        soundTimers.removeAll()
    }

    private func scheduleSound(_ sound: Sound, at date: Date) {
        guard sound.fileName != nil else { return }
        let scheduleID = soundScheduleID
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let settings = await self.center.notificationSettings()
                let now = Date.now
                guard self.soundScheduleID == scheduleID else { return }
                guard Self.shouldPlaySound(at: date, now: now,
                                           suppressed: self.isSuppressedForDictation,
                                           authorization: settings.authorizationStatus,
                                           soundSetting: settings.soundSetting) else {
                    NSLog("Aza: prayer sound skipped (offset=%.3f, suppressed=%d, authorization=%ld, sound=%ld)",
                          now.timeIntervalSince(date), self.isSuppressedForDictation ? 1 : 0,
                          settings.authorizationStatus.rawValue, settings.soundSetting.rawValue)
                    return
                }
                self.playback.play(sound)
                NSLog("Aza: prayer sound %@ (offset=%.3f)",
                      self.playback.playing == sound ? "started" : "failed", now.timeIntervalSince(date))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        soundTimers.append(timer)
    }

    /// Просроченный во сне звук не догоняет пользователя после пробуждения.
    /// Коррекция настенных часов может дать ранний callback Timer на доли
    /// секунды: строгий ноль отменял единственную попытку проиграть азан.
    static func shouldPlaySound(at date: Date, now: Date, suppressed: Bool,
                                authorization: UNAuthorizationStatus,
                                soundSetting: UNNotificationSetting) -> Bool {
        !suppressed && authorization == .authorized && soundSetting == .enabled
            && (-0.5..<5).contains(now.timeIntervalSince(date))
    }

    // MARK: Сборка запроса

    private static let identifierPrefix = "aza.prayer."

    /// Когда сработает уведомление о намазе; nil — выключено или уже
    /// прошло.
    static func fireDate(kind: PrayerKind, at date: Date, now: Date) -> Date? {
        let mode = mode(for: kind)
        guard mode != .off else { return nil }
        let fireDate = mode == .reminder
            ? date.addingTimeInterval(-Double(reminderMinutes) * 60)
            : date
        return fireDate > now ? fireDate : nil
    }

    /// Детерминированный идентификатор: повторное планирование заменяет
    /// запись, а не плодит дубликаты.
    static func identifier(city: PrayerCity, kind: PrayerKind, date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(identifierPrefix)\(city.id).\(kind.rawValue)."
            + "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
    }

    /// Календарный триггер с ЯВНЫМ часовым поясом города: интервальный
    /// таймер поехал бы при переходе на летнее время.
    private static func trigger(for date: Date, city: PrayerCity) -> UNCalendarNotificationTrigger {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = city.timeZone
        var components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        components.timeZone = city.timeZone
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }

    static func content(kind: PrayerKind, at date: Date, city: PrayerCity,
                                source: PrayerTimesSource, mode: Mode) -> UNNotificationContent {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = city.timeZone
        let time = formatter.string(from: date)

        let content = UNMutableNotificationContent()
        content.title = mode == .reminder
            ? "\(kind.title) через \(reminderMinutes) мин"
            : kind.title
        content.subtitle = city.name
        content.body = source.isVerifiedTable ? time : "\(time) · \(source.label)"
        // Файл звучит независимо от жизни баннера; второй системный
        // сигнал поверх него не нужен. Системный вариант остаётся штатным.
        content.sound = sound == .system ? .default : nil
        return content
    }
}

/// Плеер файлов для уведомлений и прослушивания в настройках.
/// Каждый владелец держит свой экземпляр: закрытие настроек не обрывает азан.
@MainActor
final class PrayerSoundPreview: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {

    /// Что звучит прямо сейчас; nil — тишина. Нужно интерфейсу, чтобы
    /// кнопка показывала «стоп» вместо «играть».
    @Published private(set) var playing: PrayerNotifications.Sound?

    private(set) var player: AVAudioPlayer?

    /// Переключатель: тот же звук останавливает, другой — начинает заново.
    func toggle(_ sound: PrayerNotifications.Sound) {
        guard playing != sound else { return stop() }
        play(sound)
    }

    func play(_ sound: PrayerNotifications.Sound) {
        stop()
        // Системный звук проиграть нечем: у него нет файла, и подменять
        // его чем-то похожим значило бы врать о том, что услышит
        // пользователь.
        guard let name = sound.fileName else { return }
        // Ищем в бандле, где лежит сам класс, а не в Bundle.main: под
        // тестами main — это раннер, и звук молча не находился бы.
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: (name as NSString).deletingPathExtension,
                                   withExtension: (name as NSString).pathExtension),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            NSLog("Aza: preview sound is missing from the bundle (%@)", name)
            return
        }
        self.player = player
        player.delegate = self
        guard player.play() else {
            NSLog("Aza: could not play sound (%@)", name)
            return stop()
        }
        playing = sound
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    func pause() { player?.pause() }

    func resume() {
        guard let player, !player.isPlaying else { return }
        if !player.play() { stop() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        if !flag { NSLog("Aza: sound playback did not finish successfully") }
        stop()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard self.player === player else { return }
        NSLog("Aza: sound decoding failed: %@", error?.localizedDescription ?? "unknown")
        stop()
    }
}
