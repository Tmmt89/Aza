import AVFoundation
import ApplicationServices
import AppKit
import Carbon.HIToolbox
import Combine
import WhisperKit

/// Диктовка (Этап 3, MVP): удержание ⌃⇧D — запись; отпускание —
/// распознавание и вставка в активное поле (спецификация §5.1).
///
/// Инварианты §5.3: аудио живёт только в памяти (стриминг с микрофона в
/// массив сэмплов), буферы очищаются при успехе, отмене и ошибке; на диск
/// пишется только модель (это разрешено). Транскрипт всегда попадает в
/// историю буфера (§5.6), даже при удачной прямой вставке.
@MainActor
final class DictationController: ObservableObject {

    enum State: Equatable {
        case idle
        case loadingModel(String)
        case recording
        case transcribing
    }

    @Published private(set) var state: State = .idle {
        didSet {
            rescheduleIdleUnload()
            updateLatchStopKeys()
        }
    }
    @Published private(set) var status = "Диктовка: удерживайте сочетание"
    /// Начало текущей записи — для таймера в острове.
    @Published private(set) var recordingStartedAt: Date?
    /// Доля загрузки модели 0…1 — для полосы прогресса в настройках.
    @Published private(set) var downloadProgress: Double?

    /// Явная загрузка выбранной модели по кнопке (§5.4): пользователь
    /// видит, что качается и сколько осталось.
    func downloadSelectedModel() {
        suppressPrewarm = false
        // В памяти может лежать ДРУГОЙ профиль — тогда prepareModel
        // молча выходил по guard whisper == nil, и кнопка не работала.
        if loadedProfile != Self.preferredProfile {
            whisper = nil
            loadedProfile = nil
        }
        prepareModel()
    }

    /// Язык, которым идёт/шла последняя диктовка (для подписи в острове).
    private(set) var activeLanguage = DictationController.preferredLanguage == "auto"
        ? "ru" : DictationController.preferredLanguage

    /// mm:ss текущей записи.
    var elapsedText: String {
        guard let start = recordingStartedAt else { return "00:00" }
        let seconds = Int(Date().timeIntervalSince(start))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// Профили моделей (§5.4). Размеры — фактические у whisperkit-coreml.
    enum Profile: String, CaseIterable, Identifiable {
        case fast, balanced, accurate

        var id: String { rawValue }

        var variant: String {
            switch self {
            case .fast: "openai_whisper-base"
            case .balanced: "openai_whisper-small"
            case .accurate: "openai_whisper-large-v3_turbo"
            }
        }

        var title: String {
            switch self {
            case .fast: "Быстрая"
            case .balanced: "Сбалансированная"
            case .accurate: "Точная"
            }
        }

        /// Только размер — для кнопки загрузки.
        var sizeLabel: String {
            switch self {
            case .fast: "150 МБ"
            case .balanced: "500 МБ"
            case .accurate: "1,5 ГБ"
            }
        }

        var summary: String {
            switch self {
            case .fast: "~150 МБ · быстрая, слабее на именах и длинных фразах"
            case .balanced: "~500 МБ · баланс скорости и точности"
            case .accurate: "~1,5 ГБ · самая точная, медленнее и тяжелее"
            }
        }
    }

    static let profileStorageKey = "DictationModelProfile"

    /// Явный выбор пользователя, если он был; иначе — разумный по
    /// умолчанию (см. resolveDefaultProfile).
    static var preferredProfile: Profile {
        guard let raw = UserDefaults.standard.string(forKey: profileStorageKey),
              let profile = Profile(rawValue: raw) else { return resolveDefaultProfile() }
        return profile
    }

    /// Пока пользователь ничего не выбирал: уже скачанная модель важнее
    /// рекомендации — качать второй раз то же самое бессмысленно. Если
    /// скачанных нет, берём подходящую этому Mac.
    static func resolveDefaultProfile() -> Profile {
        let recommended = MacCapabilities.current().recommendedProfile
        // Рекомендованная и уже скачанная — лучший вариант.
        if isModelCached(recommended) { return recommended }
        // Иначе самая точная из скачанных: качать заново то, что уже
        // лежит на диске, незачем.
        if let best = [Profile.accurate, .balanced, .fast].first(where: isModelCached) {
            return best
        }
        return recommended
    }

    /// Записывает вычисленный выбор, если пользователь ещё не выбирал:
    /// интерфейсу нужно конкретное значение для переключателя.
    static func seedDefaultProfileIfNeeded() {
        guard UserDefaults.standard.string(forKey: profileStorageKey) == nil else { return }
        UserDefaults.standard.set(resolveDefaultProfile().rawValue, forKey: profileStorageKey)
    }

    /// Вариант, который сейчас загружен в память (может отличаться от
    /// настройки, пока новая модель не скачана).
    private(set) var loadedProfile: Profile?
    private var pendingProfileChange = false

    /// Язык диктовки (§5.2): "auto" — довериться детектору, иначе
    /// принудительно "ru"/"en". Автоопределение на коротких фразах
    /// ошибается (русскую речь принимало за английскую и транслитерировало),
    /// поэтому явный выбор — не роскошь, а рабочий инструмент.
    static let languageStorageKey = "DictationLanguage"
    static var preferredLanguage: String {
        UserDefaults.standard.string(forKey: languageStorageKey) ?? "auto"
    }

    /// Предохранитель §5.1: максимум 30 минут на одну запись.
    private static let maxRecordingSeconds: TimeInterval = 30 * 60

    /// Корень кэша моделей. WhisperKit сам достраивает внутри него
    /// `models/argmaxinc/whisperkit-coreml/…`, поэтому путь должен быть
    /// именно корнем — по умолчанию это ~/Documents/huggingface, а
    /// пользовательские документы засорять нельзя.
    static var modelStorageDirectory: URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Aza", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    private var hotKey: HotKeyController?
    private var whisper: WhisperKit?
    private var audio: AudioProcessor?
    private var failsafeTimer: Timer?
    /// Поле, сфокусированное в момент старта записи, — вставляем туда же
    /// (перепроверяя secure) после распознавания.
    private var targetElement: AXUIElement?
    /// Пробная запись ради диалога TCC: результат всегда отбрасывается,
    /// поле для вставки не запоминается (активация окна сместила бы фокус).
    private var isPermissionProbe = false
    /// После удаления моделей не греем автоматически: иначе удаление
    /// немедленно обернулось бы новой загрузкой в сотни мегабайт.
    private var suppressPrewarm = false
    /// Режим фиксации (спецификация §5.1, «двойное нажатие»): запись
    /// продолжается после отпускания клавиши до повторного нажатия.
    /// Публикуется для острова: кнопка стоп видна только здесь — при
    /// удержании она бесполезна, запись останавливает отпускание клавиши.
    @Published private(set) var isLatched = false {
        didSet { updateLatchStopKeys() }
    }
    private var lastPressAt = Date.distantPast
    /// Второе нажатие в пределах этого окна включает фиксацию.
    private static let doubleTapWindow: TimeInterval = 0.5
    /// Пробел/Enter как стоп зафиксированной записи (§5.1): тап живёт
    /// только пока идёт такая запись.
    private lazy var latchStopKeys = LatchStopKeys { [weak self] in
        self?.stopFromUI()
    }

    private func updateLatchStopKeys() {
        if isLatched, state == .recording, !isPermissionProbe {
            latchStopKeys.start()
        } else {
            latchStopKeys.stop()
        }
    }

    /// Старт из меню или острова: без удерживаемой клавиши запись всегда
    /// фиксированная — её остановит повторное нажатие сочетания, Пробел,
    /// Enter или кнопка стоп.
    func startLatchedFromUI() {
        guard state == .idle else { return }
        isLatched = true
        keyDown()
        // Запись не началась (нет модели, нет доступа) — фиксация не должна
        // тихо доживать до следующего обычного удержания клавиши.
        if state != .recording { isLatched = false }
    }
    /// История буфера для транскриптов (§5.6); появляется асинхронно.
    private let clipboardStore: () -> ClipboardStore?

    init(clipboardStore: @escaping () -> ClipboardStore?) {
        self.clipboardStore = clipboardStore
    }

    func start() {
        guard hotKey == nil else { return }
        // Прогрев: модель поднимается в память ~8 секунд, и без него
        // ПЕРВОЕ нажатие уходит в ожидание, а пользователь видит «ничего
        // не происходит». Греем только когда доступ к микрофону уже есть —
        // иначе первым делом нужен диалог TCC, а не 500 МБ модели.
        // Как PrayerStore: UserDefaults надёжно виден только на следующем
        // витке main loop, иначе сохранённый профиль мог читаться как balanced.
        DispatchQueue.main.async { [weak self] in
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
            // Греем ТОЛЬКО уже скачанную модель: иначе удаление моделей
            // оборачивается новой загрузкой при следующем запуске.
            guard Self.isModelCached(Self.preferredProfile) else { return }
            self?.prepareModel()
        }
        let binding = HotKeyBinding.load(HotKeyBinding.dictationKey,
                                         fallback: .dictationDefault)
        let controller = HotKeyController(
            keyCode: binding.keyCode,
            modifiers: binding.modifiers,
            id: 2,
            onPress: { [weak self] in self?.keyDown() },
            onRelease: { [weak self] in self?.keyUp() }
        )
        hotKey = controller
        if let status = controller.register() {
            self.status = "Сочетание \(binding.display) занято другой программой"
            azaDebugLog("Aza: dictation hotkey registration FAILED status=\(status)")
            hotKey = nil
        } else {
            self.status = "Диктовка: удерживайте \(binding.display)"
            azaDebugLog("Aza: dictation hotkey registered \(binding.display)")
        }
    }

    /// Пользователь выбрал другой профиль: выгружаем модель, следующая
    /// диктовка (или прогрев) поднимет нужную.
    func profileChanged() {
        guard loadedProfile != Self.preferredProfile else {
            pendingProfileChange = false
            return
        }
        pendingProfileChange = true
        applyPendingProfileChange()
    }

    private func applyPendingProfileChange() {
        guard pendingProfileChange, state == .idle else { return }
        guard loadedProfile != Self.preferredProfile else {
            pendingProfileChange = false
            return
        }
        pendingProfileChange = false
        whisper = nil
        loadedProfile = nil
        status = "Профиль изменён — модель загрузится при следующей диктовке"
        // Скачанный профиль греем сразу, нескачанный ждёт явной диктовки:
        // смена профиля не должна сама тянуть полтора гигабайта.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           Self.isModelCached(Self.preferredProfile) {
            prepareModel()
        }
    }

    /// Есть ли модель профиля на диске (в кэше WhisperKit).
    static func isModelCached(_ profile: Profile) -> Bool {
        let folder = modelStorageDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(profile.variant, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path)
    }

    /// Выгружает модель из памяти: после удаления файлов ссылка на них
    /// бессмысленна, а автоматический прогрев скачал бы модель заново.
    func unloadModel() {
        guard state == .idle else { return }
        whisper = nil
        loadedProfile = nil
        suppressPrewarm = true
        status = "Модель удалена — загрузится при следующей диктовке"
    }

    /// Выгрузка после простоя: модель держит сотни мегабайт — гигабайты
    /// unified memory, а диктовка — редкое действие. Кэш на диске остаётся,
    /// следующее нажатие поднимет модель заново (статус это объяснит).
    // ponytail: после выгрузки первое нажатие лишь греет модель; писать
    // звук параллельно с загрузкой — апгрейд, если жалобы будут.
    private static let idleUnloadSeconds: TimeInterval = 5 * 60
    private var idleUnloadTimer: Timer?

    private func rescheduleIdleUnload() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil
        guard state == .idle, whisper != nil else { return }
        idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: Self.idleUnloadSeconds,
                                               repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .idle, self.whisper != nil else { return }
                self.whisper = nil
                self.loadedProfile = nil
                azaDebugLog("Aza: dictation model unloaded after idle")
            }
        }
    }

    func stop() {
        hotKey?.stop()
        hotKey = nil
        cancelRecording()
    }

    /// Перерегистрация после смены сочетания в настройках.
    func rebindHotKey() {
        hotKey?.stop()
        hotKey = nil
        let binding = HotKeyBinding.load(HotKeyBinding.dictationKey,
                                         fallback: .dictationDefault)
        let controller = HotKeyController(
            keyCode: binding.keyCode, modifiers: binding.modifiers, id: 2,
            onPress: { [weak self] in self?.keyDown() },
            onRelease: { [weak self] in self?.keyUp() }
        )
        hotKey = controller
        if controller.register() != nil {
            status = "Сочетание \(binding.display) занято другой программой"
            azaDebugLog("Aza: dictation rebind FAILED \(binding.display)")
            hotKey = nil
        } else {
            status = "Диктовка: удерживайте \(binding.display)"
            azaDebugLog("Aza: dictation hotkey rebound to \(binding.display)")
        }
    }

    // MARK: Жизненный цикл записи

    private func keyDown() {
        azaDebugLog("Aza: dictation keyDown state=\(state) latched=\(isLatched ? 1 : 0)")

        // Нажатие во время зафиксированной записи останавливает её
        // (спецификация §5.1); Пробел и Enter делают то же через
        // LatchStopKeys.
        if isLatched, state == .recording {
            isLatched = false
            finishRecording()
            return
        }

        // Нажатия во время загрузки модели и распознавания игнорируем
        // ЦЕЛИКОМ: иначе фиксация «залипнет» и следующая обычная запись
        // окажется зафиксированной.
        guard state == .idle || state == .recording else {
            lastPressAt = .distantPast
            return
        }

        let now = Date()
        let isDoubleTap = now.timeIntervalSince(lastPressAt) < Self.doubleTapWindow
        lastPressAt = now

        // Второе быстрое нажатие включает фиксацию. Проверяем по ВРЕМЕНИ,
        // а не по состоянию: короткое первое нажатие успевает и начать,
        // и остановить запись, поэтому к моменту второго мы уже в idle.
        if isDoubleTap, !isPermissionProbe {
            isLatched = true
            azaDebugLog("Aza: dictation latched")
            if state == .recording {
                status = "Запись зафиксирована — остановят сочетание, Пробел или Enter"
                return
            }
            // Запись успела остановиться — начинаем новую, уже фиксированную.
        }

        guard state == .idle else { return }

        let authorization = AVCaptureDevice.authorizationStatus(for: .audio)
        azaDebugLog("Aza: dictation mic auth=\(authorization.rawValue) model=\(whisper == nil ? 0 : 1)")
        switch authorization {
        case .authorized:
            break
        case .notDetermined:
            // Диалог TCC у agent-приложения (LSUIElement) не всплывает от
            // одного requestAccess — его надёжно поднимает фактическое
            // обращение к устройству. Поэтому запускаем ПРОБНУЮ запись:
            // она существует только чтобы показать запрос, её звук всегда
            // отбрасывается (пока диалог открыт, система отдаёт тишину),
            // и в любом исходе пользователь удерживает клавишу заново.
            // Модель здесь не трогаем: пробе она не нужна, а параллельные
            // загрузки при повторных нажатиях недопустимы.
            status = "Разрешите доступ к микрофону и удержите сочетание ещё раз"
            isPermissionProbe = true
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    azaDebugLog("Aza: dictation mic request granted=\(granted ? 1 : 0)")
                    self.cancelRecording()
                    self.isPermissionProbe = false
                    guard granted else {
                        self.status = "Доступ к микрофону запрещён — откройте Настройки → Конфиденциальность → Микрофон"
                        return
                    }
                    // Греем модель сразу после выдачи доступа: иначе первое
                    // же «удержите ещё раз» снова утонет в загрузке.
                    self.status = "Доступ есть, готовлю модель…"
                    self.prepareModel()
                }
            }
            beginRecording()
            return
        default:
            status = "Нет доступа к микрофону — откройте Настройки → Конфиденциальность → Микрофон"
            openMicrophoneSettings()
            return
        }

        guard whisper != nil else {
            suppressPrewarm = false
            prepareModel()
            return
        }

        beginRecording()
    }

    private static func options(for language: String, prompt: [Int]?) -> DecodingOptions {
        // Без таймстемпов: диктовке нужны слова, а не разметка по секундам,
        // и декодер тратит меньше токенов на сегмент.
        DecodingOptions(task: .transcribe, language: language,
                        usePrefillPrompt: true, withoutTimestamps: true,
                        promptTokens: prompt)
    }

    /// Свои слова: имена и термины, которые Whisper обычно коверкает.
    /// Хранятся строкой через запятую, подмешиваются в prompt декодера —
    /// модель видит их как «предыдущий текст» и склоняется к такому
    /// написанию. Обрезку длинного prompt и фильтр спец-токенов WhisperKit
    /// делает сам.
    static let customWordsStorageKey = "DictationCustomWords"

    static var customWords: [String] {
        DictationFilters.words(
            fromCustomList: UserDefaults.standard.string(forKey: customWordsStorageKey) ?? "")
    }

    private static func promptTokens(for whisper: WhisperKit) -> [Int]? {
        let words = customWords
        guard !words.isEmpty, let tokenizer = whisper.tokenizer else { return nil }
        return tokenizer.encode(text: " " + words.joined(separator: ", "))
    }

    /// Фильтр галлюцинаций (см. DictationFilters.reliableText).
    private static func reliableText(of results: [TranscriptionResult]) -> String {
        DictationFilters.reliableText(segments: results.flatMap(\.segments)
            .map { ($0.text, $0.avgLogprob, $0.noSpeechProb) })
    }

    /// Средняя уверенность распознавания: по ней сравниваем две гипотезы.
    private static func confidence(of results: [TranscriptionResult]) -> Float {
        let segments = results.flatMap(\.segments)
        guard !segments.isEmpty else { return -.infinity }
        return segments.map(\.avgLogprob).reduce(0, +) / Float(segments.count)
    }

    /// Автоопределение с приоритетом русского (§5.2).
    ///
    /// Детектор WhisperKit на коротких фразах уверенно ошибается (русскую
    /// речь принимал за английской и транслитерировал), поэтому язык
    /// выбираем по РЕЗУЛЬТАТУ. Но и распознавать всегда дважды дорого:
    /// раньше авто-режим делал детектор + два полных прогона, и обработка
    /// шла в 2–3 раза дольше одного прохода (отсюда «медленнее Handy»).
    /// Теперь русский прогон идёт первым и единственным, пока он уверенный;
    /// английский — только как проверка неуверенного результата. Русский
    /// побеждает при равенстве и в пределах форы `russianBias`.
    private static let russianBias: Float = 0.15
    /// Порог «русский прогон уверен, второй не нужен»: чистая речь на
    /// своём языке держит avgLogprob заметно выше, чужой язык — ниже.
    // ponytail: порог консервативный, подстроить по azaDebugLog scores
    private static let confidentRussianScore: Float = -0.35

    private static func autoTranscribe(
        whisper: WhisperKit, samples: [Float], prompt: [Int]?
    ) async throws -> (String, [TranscriptionResult]) {
        // Упавший прогон не должен обнулять удачный: берём то, что есть.
        let russian = try? await whisper.transcribe(
            audioArray: samples, decodeOptions: options(for: "ru", prompt: prompt))
        if let russian {
            let score = confidence(of: russian)
            azaDebugLog("Aza: dictation ru score=\(score)")
            if score >= Self.confidentRussianScore { return ("ru", russian) }
        }
        let english = try? await whisper.transcribe(
            audioArray: samples, decodeOptions: options(for: "en", prompt: prompt))
        switch (russian, english) {
        case let (russian?, english?):
            let russianScore = confidence(of: russian)
            let englishScore = confidence(of: english)
            azaDebugLog("Aza: dictation scores ru=\(russianScore) en=\(englishScore)")
            return russianScore + russianBias >= englishScore
                ? ("ru", russian)
                : ("en", english)
        case let (russian?, nil):
            return ("ru", russian)
        case let (nil, english?):
            return ("en", english)
        case (nil, nil):
            throw WhisperError.transcriptionFailed("оба прогона распознавания не удались")
        }
    }

    /// Панель «Микрофон» в системных настройках: единственный путь, когда
    /// доступ уже отклонён — повторный запрос система игнорирует.
    private func openMicrophoneSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func prepareModel() {
        // Одна загрузка за раз: прогрев при старте и нажатие клавиши
        // не должны запустить её дважды.
        guard whisper == nil, state == .idle else { return }
        guard !suppressPrewarm else { return }
        state = .loadingModel("0%")
        status = "Загрузка модели распознавания…"
        Task { [weak self] in
            // Разворачиваем сразу: дальше вложенные замыкания берут
            // константу, а не захваченную переменную — иначе Swift 6
            // считает это гонкой.
            guard let self else { return }
            do {
                let profile = Self.preferredProfile
                let folder = try await WhisperKit.download(
                    variant: profile.variant,
                    downloadBase: Self.modelStorageDirectory,
                    progressCallback: { progress in
                        Task { @MainActor in
                            // Колбэк прогресса приходит асинхронно и может
                            // опоздать: обновляем только пока грузимся,
                            // иначе вернули бы idle обратно в loadingModel.
                            guard case .loadingModel = self.state else { return }
                            let percent = Int(progress.fractionCompleted * 100)
                            self.downloadProgress = progress.fractionCompleted
                            self.state = .loadingModel("\(percent)%")
                            self.status = "Загрузка модели: \(percent)%"
                        }
                    }
                )
                // Скачивание позади — полоса прогресса уходит сразу, не
                // дожидаясь загрузки в память: это ещё несколько секунд,
                // и «100%» всё это время выглядело бы зависшим.
                self.downloadProgress = nil
                self.status = "Готовлю модель…"
                // tokenizerFolder — тоже корень кэша: токенизатор качается
                // отдельно от модели и иначе снова уедет в ~/Documents.
                let whisper = try await WhisperKit(
                    modelFolder: folder.path,
                    tokenizerFolder: Self.modelStorageDirectory,
                    load: true
                )
                self.whisper = whisper
                self.loadedProfile = profile
                self.downloadProgress = nil
                self.state = .idle
                self.status = "Модель готова (\(profile.title))"
                self.applyPendingProfileChange()
                azaDebugLog("Aza: dictation model loaded")
            } catch {
                self.state = .idle
                self.downloadProgress = nil
                self.status = "Модель не загрузилась: \(error.localizedDescription)"
                self.applyPendingProfileChange()
                azaDebugLog("Aza: dictation model load failed")
            }
        }
    }

    /// Громкость сигналов диктовки, 0…1. Ноль — без звука.
    static let toneVolumeStorageKey = "DictationToneVolume"
    static let toneVolumeDefault = 0.5

    static var toneVolume: Double {
        UserDefaults.standard.object(forKey: toneVolumeStorageKey) as? Double
            ?? toneVolumeDefault
    }

    /// Набор сигналов: у каждого — зеркальная пара (вверх — «слушаю»,
    /// вниз — «закончил», как в системной диктовке).
    enum ToneSet: String, CaseIterable {
        case classic, marimba, drop, pulse

        var title: String {
            switch self {
            case .classic: "Классика"
            case .marimba: "Маримба"
            case .drop: "Капля"
            case .pulse: "Тук"
            }
        }
    }

    static let toneSetStorageKey = "DictationToneSet"

    static var toneSet: ToneSet {
        ToneSet(rawValue: UserDefaults.standard.string(forKey: toneSetStorageKey) ?? "")
            ?? .marimba
    }

    static func playTone(start: Bool) {
        let volume = toneVolume
        let name = "dictation-\(toneSet.rawValue)-\(start ? "start" : "stop")"
        guard volume > 0,
              let url = Bundle.main.url(forResource: name, withExtension: "caf"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = Float(volume)
        sound.play()
    }

    private func beginRecording() {
        // В пробной записи фокус уже уехал на наше активированное окно —
        // запоминать его нельзя, вставлять всё равно нечего.
        targetElement = isPermissionProbe ? nil : TextInsertion.focusedElement()
        let processor = AudioProcessor()
        audio = processor
        do {
            try processor.startRecordingLive(callback: nil)
        } catch {
            audio = nil
            status = "Микрофон не запустился: \(error.localizedDescription)"
            return
        }
        state = .recording
        recordingStartedAt = Date()
        status = isLatched
            ? "Запись зафиксирована — остановят сочетание, Пробел или Enter"
            : "Запись… отпустите клавишу, чтобы вставить текст"
        // Пока острова нет, звук — единственный сигнал «пишу»: панель
        // меню пользователь в этот момент не открывает.
        if !isPermissionProbe { Self.playTone(start: true) }
        failsafeTimer = Timer.scheduledTimer(withTimeInterval: Self.maxRecordingSeconds,
                                             repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = "Достигнут предел 30 минут — останавливаю"
                self.isLatched = false
                // Пробную запись нельзя отправлять в распознавание: модели
                // может не быть, и состояние застряло бы в .transcribing.
                if self.isPermissionProbe {
                    self.cancelRecording()
                } else {
                    self.finishRecording()
                }
            }
        }
        azaDebugLog("Aza: dictation recording started")
    }

    private func cancelRecording() {
        isLatched = false
        failsafeTimer?.invalidate()
        failsafeTimer = nil
        audio?.stopRecording()
        audio?.purgeAudioSamples(keepingLast: 0)
        audio = nil
        targetElement = nil
        recordingStartedAt = nil
        // Сбрасывать в idle можно только из записи: во время загрузки
        // модели это открыло бы дверь параллельным загрузкам (guard в
        // keyDown пропускает только idle).
        if state == .recording { state = .idle }
    }

    private func keyUp() {
        azaDebugLog("Aza: dictation keyUp state=\(state) latched=\(isLatched ? 1 : 0)")
        // Пробную запись (диалог TCC) просто гасим: распознавать тишину,
        // записанную пока открыт системный запрос, незачем.
        guard !isPermissionProbe else {
            cancelRecording()
            return
        }
        // В режиме фиксации отпускание клавиши ничего не значит — запись
        // остановит следующее нажатие.
        guard !isLatched else { return }
        finishRecording()
    }

    /// Остановка записи из интерфейса (кнопка в острове, §5.1).
    /// Не путать со `stop()`, который снимает хоткей и гасит контроллер.
    func stopFromUI() {
        guard state == .recording else { return }
        // Пробную запись (диалог TCC) не распознаём: модели может не быть,
        // и состояние застряло бы в .transcribing.
        guard !isPermissionProbe else {
            cancelRecording()
            return
        }
        isLatched = false
        finishRecording()
    }

    /// Останавливает запись и запускает распознавание. Общий путь для
    /// отпускания клавиши, остановки фиксации и 30-минутного предохранителя.
    private func finishRecording() {
        guard state == .recording, let processor = audio else { return }
        failsafeTimer?.invalidate()
        failsafeTimer = nil

        processor.stopRecording()
        let samples = Array(processor.audioSamples)
        processor.purgeAudioSamples(keepingLast: 0)
        audio = nil
        azaDebugLog("Aza: dictation stopped samples=\(samples.count)")

        // Короче ~0,3 с — случайное нажатие, распознавать нечего.
        guard samples.count > 4800 else {
            state = .idle
            status = "Слишком короткая запись"
            targetElement = nil
            applyPendingProfileChange()
            return
        }

        guard DictationFilters.hasSpeech(samples) else {
            state = .idle
            status = "Тишина — ничего не распознано"
            targetElement = nil
            applyPendingProfileChange()
            azaDebugLog("Aza: dictation skipped, no speech energy")
            return
        }

        state = .transcribing
        recordingStartedAt = nil
        status = "Распознаю…"
        Self.playTone(start: false)
        let element = targetElement
        targetElement = nil

        Task { [weak self] in
            guard let self, let whisper = self.whisper else {
                azaDebugLog("Aza: dictation transcribe skipped (no self/model)")
                return
            }
            azaDebugLog("Aza: dictation transcribe begin")
            do {
                // §5.2: русский, английский или автоопределение между ними.
                let language: String
                var results: [TranscriptionResult]
                let prompt = Self.promptTokens(for: whisper)

                if Self.preferredLanguage == "auto" {
                    (language, results) = try await Self.autoTranscribe(
                        whisper: whisper, samples: samples, prompt: prompt)
                } else {
                    language = Self.preferredLanguage
                    results = try await whisper.transcribe(
                        audioArray: samples,
                        decodeOptions: Self.options(for: language, prompt: prompt))
                }
                azaDebugLog("Aza: dictation language=\(language) results=\(results.count)")
                self.activeLanguage = language
                let text = Self.reliableText(of: results)
                self.finish(text: text, language: language, element: element)
            } catch {
                self.state = .idle
                self.status = "Распознавание не удалось: \(error.localizedDescription)"
                self.applyPendingProfileChange()
                azaDebugLog("Aza: dictation transcribe failed")
            }
        }
    }

    private func finish(text: String, language: String, element: AXUIElement?) {
        state = .idle
        guard !text.isEmpty else {
            status = "Ничего не распознано"
            applyPendingProfileChange()
            return
        }
        azaDebugLog("Aza: dictation done lang=\(language) len=\(text.count)")

        // §5.6: транскрипт всегда в буфер и историю — вставка лишь бонус.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        clipboardStore()?.add(text: text,
                              sourceAppBundleID: Bundle.main.bundleIdentifier,
                              sourceAppName: "Aza (диктовка)")

        // Вставляем в поле, где курсор СЕЙЧАС, но только если это то же
        // приложение, что и в момент начала записи: так текст не уедет
        // туда, куда пользователь переключился за время распознавания.
        // Сравнивать сами элементы нельзя — система отдаёт новую обёртку
        // для того же поля, и вставка не срабатывала никогда.
        let current = TextInsertion.focusedElement()
        let sameApp = element.flatMap(TextInsertion.processID(of:))
            == current.flatMap(TextInsertion.processID(of:))
        azaDebugLog("Aza: dictation insert target=\(element == nil ? 0 : 1) current=\(current == nil ? 0 : 1) sameApp=\(sameApp ? 1 : 0)")

        if let current, sameApp,
           !SecureFieldDetector.isSecure(current),
           TextInsertion.isTextLike(current),
           TextInsertion.insert(text, into: current) == .success {
            status = "Вставлено (\(language)): \(text.prefix(60))"
        } else {
            status = "Текст в буфере (⌘V): \(text.prefix(60))"
        }
        applyPendingProfileChange()
    }
}
