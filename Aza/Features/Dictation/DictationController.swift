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
            cancelWarmup()
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
    /// Процесс приложения, где шла запись: страховка для вставки, когда AX
    /// не отдал элемент (Electron/webview) — сверяем хотя бы приложение.
    private var targetAppPid: pid_t?
    /// Запись закончилась раньше, чем поднялась модель: звук ждёт её здесь,
    /// распознавание стартует из завершения prepareModel.
    private var pendingSamples: [Float]?
    private var pendingElement: AXUIElement?
    private var pendingPid: pid_t?
    /// Идёт загрузка/подготовка модели (в т.ч. фоновая, параллельно записи):
    /// защита от второй параллельной загрузки.
    private var isLoadingModel = false
    /// Какой профиль грузится СЕЙЧАС: настройка могла смениться на лету,
    /// и сверять удаление/отмену нужно с захваченным профилем, не с ней.
    private var loadingProfile: Profile?
    /// Результат летящей загрузки нужно выбросить (файлы модели удалены).
    /// Отдельно от suppressPrewarm: тот сбрасывается явным нажатием
    /// клавиши, что не должно оживлять ссылку на стёртые файлы.
    private var discardCurrentLoad = false
    /// Сам Task загрузки — чтобы отменять: не отменённое скачивание
    /// продолжало бы ПЕРЕСОЗДАВАТЬ только что удалённые файлы модели.
    private var loadTask: Task<Void, Never>?
    /// Холостой прогон после загрузки: первое распознавание платит за
    /// раскрутку ANE (специализация CoreML) — переносим её в фоновый
    /// прогрев, чтобы первая реальная диктовка шла уже на горячей модели.
    /// Реальное распознавание дожидается прогрева (await value).
    private var warmupTask: Task<Void, Never>?

    /// Отменённая работа модели (прогревы И стрим-циклы), которая могла ещё
    /// крутиться: cancel неблокирующий, и барьеры удаления с новыми
    /// прогонами обязаны дождаться каждого — обнуление одной ссылки
    /// оставляло бы «await ничего» при живом прогоне.
    private var retiredWarmups: [Task<Void, Never>] = []

    /// Дождаться ВСЕЙ отменённой работы модели: два одновременных прогона
    /// на одном экземпляре WhisperKit не допускаются.
    private func awaitRetiredModelWork() async {
        let retiring = retiredWarmups
        retiredWarmups = []
        for task in retiring { await task.value }
    }

    /// Прогрев живёт вместе с моделью: смена профиля, выгрузка и удаление
    /// гасят его — иначе транскрипция могла бы ждать прогрев УЖЕ выгруженной
    /// модели, а удаление файлов гонялось бы с её холостым прогоном.
    /// Новые транскрипции отменённый прогон не ждут (warmupTask = nil);
    /// ссылка уходит в retiredWarmups до ближайшего drainWarmup.
    private func cancelWarmup() {
        if let warmupTask {
            warmupTask.cancel()
            retiredWarmups.append(warmupTask)
        }
        warmupTask = nil
    }

    /// Для барьеров удаления: дождаться, пока ВСЯ отменённая работа модели
    /// реально остановится — файлы нельзя стирать под работающей моделью.
    private func drainWarmup() async {
        cancelWarmup()
        await awaitRetiredModelWork()
    }

    /// Идёт удаление файлов моделей: ЛЮБЫЕ новые загрузки запрещены.
    /// Нажатие клавиши во время await барьера удаления иначе сбрасывало
    /// suppressPrewarm и воскрешало стираемую модель — цикл барьера мог
    /// не завершиться никогда.
    private var modelDeletionInProgress = false
    /// Для острова: экран распознавания показывает «Загружаю модель…»
    /// вместо «Распознаю…», пока звук ждёт модель.
    @Published private(set) var isAwaitingModel = false
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
            // Фоновый режим: прогрев не занимает состояние, и нажатие
            // клавиши во время прогрева сразу пишет звук.
            self?.prepareModel(ownsState: false)
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
        // Не во время загрузки: prepareModel всё равно заблокирован, а
        // сброс pendingProfileChange здесь оставил бы старый профиль
        // активным навсегда. Завершение загрузки вызовет нас снова.
        guard pendingProfileChange, state == .idle, !isLoadingModel else { return }
        guard loadedProfile != Self.preferredProfile else {
            pendingProfileChange = false
            return
        }
        pendingProfileChange = false
        cancelWarmup()
        whisper = nil
        loadedProfile = nil
        status = "Профиль изменён — модель загрузится при следующей диктовке"
        // Скачанный профиль греем сразу, нескачанный ждёт явной диктовки:
        // смена профиля не должна сама тянуть полтора гигабайта.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           Self.isModelCached(Self.preferredProfile) {
            prepareModel(ownsState: false)
        }
    }

    /// Папка модели профиля в кэше WhisperKit.
    static func cachedModelFolder(_ profile: Profile) -> URL {
        modelStorageDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(profile.variant, isDirectory: true)
    }

    /// Есть ли модель профиля на диске (в кэше WhisperKit).
    static func isModelCached(_ profile: Profile) -> Bool {
        FileManager.default.fileExists(atPath: cachedModelFolder(profile).path)
    }

    /// Выгружает модель из памяти: после удаления файлов ссылка на них
    /// бессмысленна, а автоматический прогрев скачал бы модель заново.
    func unloadModel() {
        guard state == .idle else { return }
        cancelWarmup()
        whisper = nil
        loadedProfile = nil
        suppressPrewarm = true
        // Летящая загрузка (массовое удаление стирает ВСЕ модели):
        // результат — ссылка на стёртые файлы, а само скачивание
        // пересоздавало бы их — отменяем.
        if isLoadingModel {
            discardCurrentLoad = true
            loadTask?.cancel()
        }
        status = "Модель удалена — загрузится при следующей диктовке"
    }

    /// Полная остановка загрузок перед МАССОВЫМ удалением моделей:
    /// уборка отменённого загрузчика может сама поднять следующего
    /// (retry ожидающего звука, отложенная смена профиля) — глушим
    /// респаун через suppressPrewarm и отменяем каждого, пока не
    /// останется ни одного.
    func shutdownLoadersForDeletion() async {
        modelDeletionInProgress = true
        // Сброс в defer: PrivacyCleanup зовётся сразу после await в том же
        // синхронном участке MainActor — вклиниться keyDown уже не успеет.
        defer { modelDeletionInProgress = false }
        suppressPrewarm = true
        while isLoadingModel, let task = loadTask {
            discardCurrentLoad = true
            task.cancel()
            await task.value
        }
        // Холостой прогон тоже гоняет модель — файлы нельзя стирать,
        // пока он не остановился.
        await drainWarmup()
    }

    /// Удаление файлов одного профиля целиком: выгрузка/отмена загрузчика,
    /// ожидание его остановки, затем стирание файлов. Возвращает ошибку
    /// PrivacyCleanup или nil.
    ///
    /// Барьер ждёт и отменяет только загрузчики УДАЛЯЕМОГО профиля.
    /// Цепные загрузки (retry ожидающего звука, отложенная смена профиля)
    /// всегда грузят Self.preferredProfile: при preferred == profile они
    /// заглушены suppressPrewarm (см. prepareForModelDeletion) — цикл
    /// конечен; чужой профиль пишет в свою папку и удалению не мешает.
    func deleteModelFiles(_ profile: Profile) async -> String? {
        // Кнопка в UI выключена при занятости, но между кликом и стартом
        // Task диктовка могла начаться — граница API обязана проверить сама:
        // стирать файлы под живой моделью нельзя.
        guard state == .idle else { return "диктовка занята — попробуйте снова" }
        modelDeletionInProgress = true
        defer { modelDeletionInProgress = false }
        prepareForModelDeletion(profile)
        while isLoadingModel, let task = loadTask, loadingProfile == profile {
            discardCurrentLoad = true
            task.cancel()
            await task.value
        }
        // Прогрев мог идти на удаляемом профиле — дожидаемся остановки.
        await drainWarmup()
        return PrivacyCleanup.deleteModel(variant: profile.variant)
    }

    /// Перед удалением файлов ОДНОГО профиля: выгрузить его из памяти и
    /// не дать летящей фоновой загрузке (loadedProfile ещё nil) оживить
    /// ссылку на стёртые файлы — её завершение смотрит на discardCurrentLoad.
    private func prepareForModelDeletion(_ profile: Profile) {
        guard state == .idle else { return }
        if loadedProfile == profile { unloadModel() }
        // Удаляется ТЕКУЩИЙ предпочитаемый профиль: цепные загрузки грузят
        // именно его — глушим прогрев независимо от того, что грузится
        // прямо сейчас (грузиться может и A при удалении preferred B).
        if Self.preferredProfile == profile { suppressPrewarm = true }
        if isLoadingModel, loadingProfile == profile {
            discardCurrentLoad = true
            loadTask?.cancel()
        }
    }

    /// Выгрузка после простоя: модель держит сотни мегабайт — гигабайты
    /// unified memory. Кэш на диске остаётся; следующее нажатие пишет
    /// звук сразу, а модель греется параллельно (см. keyDown). Срок —
    /// настройка (идея Handy): 0 = «никогда», по умолчанию 30 минут
    /// (жалоба владельца на частые холодные старты при прежних 5).
    static let unloadTimeoutStorageKey = "DictationUnloadMinutes"
    /// Допустимые значения зашиты: чужая запись в defaults не должна
    /// ронять приложение (Int-переполнение в minutes * 60) или оставлять
    /// Picker без выбранного пункта — незнакомое значение читается как 30.
    static let unloadMinuteChoices = [0, 5, 30, 60]
    static var unloadMinutes: Int {
        let raw = UserDefaults.standard.object(forKey: unloadTimeoutStorageKey) as? Int ?? 30
        return unloadMinuteChoices.contains(raw) ? raw : 30
    }
    private var idleUnloadTimer: Timer?

    /// Смена настройки применяется сразу: «никогда» снимает уже взведённый
    /// таймер, укорочение — перевзводит.
    func unloadTimeoutChanged() {
        rescheduleIdleUnload()
    }

    private func rescheduleIdleUnload() {
        idleUnloadTimer?.invalidate()
        idleUnloadTimer = nil
        guard state == .idle, whisper != nil else { return }
        let minutes = Self.unloadMinutes
        guard minutes > 0 else { return }
        idleUnloadTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes) * 60,
                                               repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .idle, self.whisper != nil else { return }
                self.cancelWarmup()
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
                    self.prepareModel(ownsState: false)
                }
            }
            beginRecording()
            return
        default:
            // Фиксация не должна пережить отказ: иначе следующее одиночное
            // нажатие неожиданно начнёт зафиксированную запись.
            isLatched = false
            status = "Нет доступа к микрофону — откройте Настройки → Конфиденциальность → Микрофон"
            openMicrophoneSettings()
            return
        }

        // Модели в памяти нет — пишем звук СРАЗУ, модель греется
        // параллельно: нажатие не должно уходить в пустое ожидание.
        // Если запись кончится раньше загрузки, звук подождёт модель
        // (pendingSamples), остров покажет «Загружаю модель…».
        if whisper == nil {
            suppressPrewarm = false
            prepareModel(ownsState: false)
        }
        beginRecording()
    }

    private static func options(for language: String, prompt: [Int]?) -> DecodingOptions {
        // Без таймстемпов: диктовке нужны слова, а не разметка по секундам,
        // и декодер тратит меньше токенов на сегмент.
        // temperatureFallbackCount 1 (дефолт 5): на «неуверенных» сегментах
        // декодер перезапускается с ростом температуры — для диктовки
        // пятикратный пересчёт лишний, одного повтора достаточно.
        // VAD-чанкинг: длинная запись режется по паузам и окна идут
        // параллельно (дефолтные 16 воркеров macOS); короткая запись —
        // один чанк, накладных расходов нет.
        DecodingOptions(task: .transcribe, language: language,
                        temperatureFallbackCount: 1,
                        usePrefillPrompt: true, withoutTimestamps: true,
                        promptTokens: prompt,
                        chunkingStrategy: .vad)
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

    // MARK: Стриминговая пред-транскрипция (приём Handy)

    /// Распознавание ВО ВРЕМЯ записи: каждые ~2 с накопившийся буфер
    /// прогоняется с clipTimestamps от подтверждённой границы (алгоритм
    /// WhisperKit AudioStreamTranscriber, перенесённый на наш конвейер
    /// записи — их актор владеет микрофоном сам и не совместим с пробой
    /// TCC/фиксацией/предохранителем). К отпусканию клавиши распознан
    /// почти весь текст, финал — только хвост. Работает при ЯВНОМ языке
    /// (§5.2): в «Авто» язык выбирается по результату целой записи, и
    /// стримить нечем — там остаётся пакетный путь.
    static let streamingStorageKey = "DictationStreaming"
    static var streamingEnabled: Bool {
        (UserDefaults.standard.object(forKey: streamingStorageKey) as? Bool) ?? true
    }

    private var streamTask: Task<Void, Never>?
    /// Подтверждённые стримом сегменты и граница подтверждения в секундах.
    private var streamSegments: [(text: String, avgLogprob: Float, noSpeechProb: Float)] = []
    private var streamConfirmedEnd: Float = 0
    /// Язык, захваченный при СТАРТЕ стрима: смена языка в настройках
    /// посреди записи не должна дать префикс на одном языке и хвост на другом.
    private var streamLanguage: String?
    private var streamBuffer: StreamBuffer?

    /// Потокобезопасная копия звука для стрима: тап AVAudioEngine дописывает
    /// audioSamples БЕЗ синхронизации, и читать её во время записи — гонка
    /// (у родного AudioStreamTranscriber она тоже есть). Пишем свою копию
    /// под замком из колбэка startRecordingLive; читаем снапшотом.
    private final class StreamBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        func append(_ chunk: [Float]) {
            lock.lock()
            samples.append(contentsOf: chunk)
            lock.unlock()
        }

        func snapshot() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return samples.count
        }
    }

    private func stopStreaming() {
        // Отменённый цикл мог держать модель в текущем проходе: в ретайр,
        // как прогревы, — barriers удаления и новые прогоны его дождутся.
        if let streamTask {
            streamTask.cancel()
            retiredWarmups.append(streamTask)
        }
        streamTask = nil
        streamBuffer = nil
        streamSegments = []
        streamConfirmedEnd = 0
        streamLanguage = nil
    }

    private func startStreaming(buffer: StreamBuffer, whisper: WhisperKit) {
        let language = Self.preferredLanguage
        streamSegments = []
        streamConfirmedEnd = 0
        streamLanguage = language
        // Снапшот отменённой работы — ДО создания задачи: awaitRetired
        // изнутри само-дедлочился бы, если стрим отменят во время await
        // прогрева (задача попадает в ретайр и ждала бы собственный value).
        let predecessors = retiredWarmups
        retiredWarmups = []
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.warmupTask?.value
            for task in predecessors { await task.value }
            let prompt = Self.promptTokens(for: whisper)
            var lastCount = 0
            while !Task.isCancelled, self.state == .recording,
                  self.streamBuffer === buffer {
                // Меньше 2 с новых сэмплов — подождать следующего среза.
                guard buffer.count - lastCount >= 32_000 else {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                let samples = buffer.snapshot()
                let newSlice = Array(samples[lastCount...])
                lastCount = samples.count
                // Новый срез без речи (пауза в диктовке): прогон не нужен —
                // граница подтверждения не сдвинется, а энкодер жёг бы
                // энергию впустую (та же логика useVAD у родного
                // AudioStreamTranscriber).
                guard DictationFilters.hasSpeech(newSlice) else { continue }
                var options = Self.options(for: language, prompt: prompt)
                options.chunkingStrategy = nil // срез короткий, чанки не нужны
                // Стриму нужны таймстемпы: без них Whisper отдаёт один
                // грубый сегмент на окно, и подтверждать нечего.
                options.withoutTimestamps = false
                options.clipTimestamps = self.streamConfirmedEnd > 0
                    ? [self.streamConfirmedEnd] : []
                guard let results = try? await whisper.transcribe(
                    audioArray: samples, decodeOptions: options) else { continue }
                guard !Task.isCancelled, self.state == .recording,
                      self.streamBuffer === buffer else { break }
                // Последние 2 сегмента не подтверждаем — их ещё «дожуёт»
                // следующий проход (правило AudioStreamTranscriber).
                let segments = results.flatMap(\.segments)
                guard segments.count > 2 else { continue }
                let confirmed = segments.dropLast(2)
                guard let last = confirmed.last,
                      last.end > self.streamConfirmedEnd else { continue }
                self.streamConfirmedEnd = last.end
                self.streamSegments.append(contentsOf: confirmed.map {
                    (text: $0.text, avgLogprob: $0.avgLogprob, noSpeechProb: $0.noSpeechProb)
                })
                azaDebugLog("Aza: dictation stream confirmed=\(self.streamSegments.count) end=\(self.streamConfirmedEnd)")
            }
        }
    }

    /// Убирать звуки-паразиты («эм», «э-э», "uh") из транскрипта.
    static let removeFillersStorageKey = "DictationRemoveFillers"
    static var removeFillers: Bool {
        (UserDefaults.standard.object(forKey: removeFillersStorageKey) as? Bool) ?? true
    }

    /// Финальный текст из сегментов: фильтр галлюцинаций (см.
    /// DictationFilters.reliableText), по настройке — звуков-паразитов,
    /// и fuzzy-притяжка своих слов (пустой список — no-op).
    private static func finishText(
        segments: [(text: String, avgLogprob: Float, noSpeechProb: Float)]
    ) -> String {
        var text = DictationFilters.reliableText(segments: segments)
        if removeFillers { text = DictationFilters.removingFillerSounds(from: text) }
        return DictationFilters.applyingCustomWords(to: text, words: customWords)
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

    /// Запись длиннее этого — язык решает детектор: на длинной речи он
    /// надёжен, а «второй полный прогон» именно там дороже всего (средний
    /// logprob длинной диктовки естественно ниже порога уверенности, и
    /// реальная русская запись на 15 с получала ещё 14 с английского
    /// прогона, который проигрывал с разницей 0.0004 и выбрасывался).
    private static let detectorMinSamples = 10 * 16000

    private static func autoTranscribe(
        whisper: WhisperKit, samples: [Float], prompt: [Int]?
    ) async throws -> (String, [TranscriptionResult]) {
        // Длинная запись: один быстрый вызов детектора (проход энкодера
        // + один шаг декодера) вместо двух полных прогонов. Всё, что не
        // английский, — русский: §5.2 поддерживает только эти два языка,
        // приоритет русского. Detected-язык логируется без содержимого.
        if samples.count >= Self.detectorMinSamples,
           let detected = try? await whisper.detectLangauge(
               audioArray: Array(samples.prefix(30 * 16000))).language {
            azaDebugLog("Aza: dictation detector language=\(detected)")
            let language = detected == "en" ? "en" : "ru"
            let results = try await whisper.transcribe(
                audioArray: samples,
                decodeOptions: options(for: language, prompt: prompt))
            return (language, results)
        }
        // Короткие фразы: схема «по результату» — детектор на них
        // ошибается (русскую речь принимал за английскую), а лишний
        // прогон короткой записи дешёвый.
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

    /// `ownsState: false` — фоновая загрузка параллельно записи: состояние
    /// не трогаем (оно принадлежит записи/распознаванию), прогресс идёт
    /// только в status.
    private func prepareModel(ownsState: Bool = true) {
        // Одна загрузка за раз: прогрев при старте и нажатие клавиши
        // не должны запустить её дважды.
        guard whisper == nil, !isLoadingModel else { return }
        guard !suppressPrewarm, !modelDeletionInProgress else { return }
        if ownsState {
            // Явная загрузка (кнопка в настройках) занимает состояние —
            // только из покоя. Фоновая (ownsState: false) состояния не
            // трогает и может стартовать даже из finishRecording
            // (перезапуск упавшего загрузчика при припаркованном звуке).
            guard state == .idle else { return }
            state = .loadingModel("0%")
        }
        isLoadingModel = true
        let profile = Self.preferredProfile
        loadingProfile = profile
        status = "Загрузка модели распознавания…"
        loadTask = Task { [weak self] in
            // Разворачиваем сразу: дальше вложенные замыкания берут
            // константу, а не захваченную переменную — иначе Swift 6
            // считает это гонкой.
            guard let self else { return }
            let loadStart = Date()
            do {
                // Кэш на месте — сеть не нужна: WhisperKit.download даже при
                // полном кэше ходит на Hugging Face сверять ревизию, и каждый
                // подъём модели платил секунды сети (офлайн — ждал таймаута).
                // Битый кэш ловится ниже: неудачная загрузка из кэша один раз
                // повторяется через полноценный download.
                var folder = Self.cachedModelFolder(profile)
                let usedCache = Self.isModelCached(profile)
                let progressCallback: (Progress) -> Void = { progress in
                    Task { @MainActor in
                        // Колбэк прогресса приходит асинхронно и может
                        // опоздать: обновляем только пока грузимся.
                        guard self.isLoadingModel else { return }
                        let percent = Int(progress.fractionCompleted * 100)
                        self.downloadProgress = progress.fractionCompleted
                        // Состояние — только если оно наше: при фоновой
                        // загрузке им владеет запись/распознавание.
                        if case .loadingModel = self.state {
                            self.state = .loadingModel("\(percent)%")
                        }
                        self.status = "Загрузка модели: \(percent)%"
                    }
                }
                if !usedCache {
                    folder = try await WhisperKit.download(
                        variant: profile.variant,
                        downloadBase: Self.modelStorageDirectory,
                        progressCallback: progressCallback
                    )
                    // Скачивание позади — полоса прогресса уходит сразу, не
                    // дожидаясь загрузки в память: это ещё несколько секунд,
                    // и «100%» всё это время выглядело бы зависшим.
                    self.downloadProgress = nil
                }
                self.status = "Готовлю модель…"
                // Отмена, пришедшая после скачивания: не тратить секунды
                // на загрузку в память модели, которую уже удалили.
                try Task.checkCancellation()
                // tokenizerFolder — тоже корень кэша: токенизатор качается
                // отдельно от модели и иначе снова уедет в ~/Documents.
                let whisper: WhisperKit
                do {
                    whisper = try await WhisperKit(
                        modelFolder: folder.path,
                        tokenizerFolder: Self.modelStorageDirectory,
                        load: true
                    )
                } catch where usedCache && !Task.isCancelled {
                    // Кэш подвёл. Ступень 1 — дешёвый ремонт: download со
                    // сверкой commit докачивает недостающие файлы (прерванная
                    // закачка — частый случай) и заодно переживает транзиентный
                    // сбой инициализации, НЕ трогая полтора гигабайта целых.
                    azaDebugLog("Aza: cached model load failed, repairing")
                    self.status = "Кэш модели повреждён — восстанавливаю…"
                    var repairDownloadSucceeded = false
                    do {
                        let repaired = try await WhisperKit.download(
                            variant: profile.variant,
                            downloadBase: Self.modelStorageDirectory,
                            progressCallback: progressCallback)
                        repairDownloadSucceeded = true
                        self.downloadProgress = nil
                        try Task.checkCancellation()
                        whisper = try await WhisperKit(
                            modelFolder: repaired.path,
                            tokenizerFolder: Self.modelStorageDirectory,
                            load: true
                        )
                    } catch where repairDownloadSucceeded && !Task.isCancelled {
                        // Ступень 2 — ТОЛЬКО когда докачка со сверкой прошла
                        // (сеть есть, состав по commit на месте), а init всё
                        // равно упал: байты биты локально, докачка их не
                        // заменит (совпавший commit не хэшируется). Сбой самой
                        // докачки (офлайн, HF) кэш НЕ сносит — честная ошибка,
                        // модель цела до следующей попытки. Снос — fail-closed:
                        // не удалилось — ошибка, а не повтор тех же байтов.
                        azaDebugLog("Aza: repair failed, full redownload")
                        try FileManager.default.removeItem(at: folder)
                        self.status = "Кэш модели повреждён — скачиваю заново…"
                        let fresh = try await WhisperKit.download(
                            variant: profile.variant,
                            downloadBase: Self.modelStorageDirectory,
                            progressCallback: progressCallback)
                        self.downloadProgress = nil
                        try Task.checkCancellation()
                        whisper = try await WhisperKit(
                            modelFolder: fresh.path,
                            tokenizerFolder: Self.modelStorageDirectory,
                            load: true
                        )
                    }
                }
                // Пока грузились, модель удалили из настроек: ссылку на
                // стёртые файлы не оживляем. Флаг отдельный от
                // suppressPrewarm — тот сбрасывается явным нажатием
                // клавиши и не должен «прощать» удаление на лету.
                guard !self.discardCurrentLoad else {
                    self.finishDiscardedLoad()
                    return
                }
                azaDebugLog(String(format: "Aza: dictation model ready in %.1fs cache=%d",
                                   Date().timeIntervalSince(loadStart), usedCache ? 1 : 0))
                self.whisper = whisper
                self.loadedProfile = profile
                self.loadingProfile = nil
                self.downloadProgress = nil
                self.isLoadingModel = false
                // Состояние возвращаем, только если владели им; при фоновой
                // загрузке оно у записи/распознавания.
                if case .loadingModel = self.state { self.state = .idle }
                azaDebugLog("Aza: dictation model loaded")
                // Звук уже ждёт модель — сразу в распознавание, сообщение
                // «Загружаю модель…» в острове сменяется на «Распознаю…».
                if let samples = self.pendingSamples {
                    let element = self.pendingElement
                    let pid = self.pendingPid
                    self.pendingSamples = nil
                    self.pendingElement = nil
                    self.pendingPid = nil
                    self.isAwaitingModel = false
                    self.status = "Распознаю…"
                    self.transcribe(samples: samples, whisper: whisper,
                                    element: element, targetPid: pid)
                } else {
                    self.status = "Модель готова (\(profile.title))"
                    self.applyPendingProfileChange()
                    // Фоновая загрузка завершилась при state == .idle:
                    // didSet не сработает — таймер выгрузки ставим сами,
                    // иначе модель жила бы в памяти вечно.
                    self.rescheduleIdleUnload()
                    // Прогрев — только когда звук НЕ ждал модель (ожидавший
                    // звук сам прогревает её первым реальным прогоном) И
                    // модель всё ещё актуальна: applyPendingProfileChange
                    // строкой выше могла применить отложенную смену A→B и
                    // выгрузить только что загруженную A — прогрев устаревшей
                    // модели ждала бы транскрипция B, а барьер удаления его
                    // не видел бы.
                    if self.whisper != nil, self.loadedProfile == profile {
                        self.warmupTask = Task {
                            _ = try? await whisper.transcribe(
                                audioArray: [Float](repeating: 0, count: 16000),
                                decodeOptions: Self.options(for: "ru", prompt: nil))
                            azaDebugLog("Aza: dictation model warmed")
                        }
                    }
                }
            } catch {
                // Отменённая (удалённая на лету) загрузка падает сюда же —
                // CancellationError из download: та же уборка, что и при
                // «успехе с discard», а не «Модель не загрузилась».
                if self.discardCurrentLoad {
                    self.finishDiscardedLoad()
                    return
                }
                self.isLoadingModel = false
                self.loadingProfile = nil
                self.downloadProgress = nil
                if case .loadingModel = self.state { self.state = .idle }
                // Припаркованный звук без модели не распознать — честно
                // отпускаем экран ожидания.
                if self.pendingSamples != nil {
                    self.pendingSamples = nil
                    self.pendingElement = nil
                    self.pendingPid = nil
                    self.isAwaitingModel = false
                    if self.state == .transcribing { self.state = .idle }
                }
                self.status = "Модель не загрузилась: \(error.localizedDescription)"
                self.applyPendingProfileChange()
                azaDebugLog("Aza: dictation model load failed")
            }
        }
    }

    /// Уборка отменённой на лету загрузки (модель удалили из настроек):
    /// общая для guard-ветки успеха и catch после cancel(). Ожидающий
    /// звук пробует актуальный профиль; отложенная смена профиля
    /// применяется; статус не застревает на «Готовлю модель…».
    private func finishDiscardedLoad() {
        cancelWarmup()
        discardCurrentLoad = false
        isLoadingModel = false
        loadingProfile = nil
        downloadProgress = nil
        if case .loadingModel = state { state = .idle }
        if pendingSamples != nil {
            prepareModel(ownsState: false)
            if !isLoadingModel {
                pendingSamples = nil
                pendingElement = nil
                pendingPid = nil
                isAwaitingModel = false
                if state == .transcribing { state = .idle }
                status = "Модель удалена — звук не распознан"
            }
        } else {
            status = "Модель удалена — загрузится при следующей диктовке"
            applyPendingProfileChange()
        }
        azaDebugLog("Aza: dictation model load discarded (deleted)")
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
        // Элемента может не быть (Electron/webview до пробуждения AX) —
        // тогда идентичность цели держит хотя бы pid фронтмоста.
        targetAppPid = isPermissionProbe ? nil
            : (targetElement.flatMap(TextInsertion.processID(of:))
               ?? NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let processor = AudioProcessor()
        audio = processor
        // Копия звука для стрима собирается прямо из колбэка записи —
        // читать processor.audioSamples во время записи нельзя (гонка).
        let buffer = (!isPermissionProbe && whisper != nil
                      && Self.streamingEnabled && Self.preferredLanguage != "auto")
            ? StreamBuffer() : nil
        // startRecordingLive присваивает колбэк уже ПОСЛЕ запуска движка:
        // первые ~100–400 мс (раскрутка) долетают в audioSamples мимо нашей
        // копии. Это не чинится снаружи без гонки на audioBufferCallback,
        // поэтому в стрим-режиме финал идёт по ТОЙ ЖЕ копии (см.
        // finishRecording) — таймлайны совпадают конструктивно, а голова
        // отброшена из обоих проходов одинаково (пользователь начинает
        // говорить после сигнала — терять там нечего).
        let capture: (([Float]) -> Void)? = buffer.map { buffer in
            { chunk in buffer.append(chunk) }
        }
        do {
            try processor.startRecordingLive(callback: capture)
        } catch {
            audio = nil
            status = "Микрофон не запустился: \(error.localizedDescription)"
            return
        }
        streamBuffer = buffer
        state = .recording
        recordingStartedAt = Date()
        status = isLatched
            ? "Запись зафиксирована — остановят сочетание, Пробел или Enter"
            : "Запись… отпустите клавишу, чтобы вставить текст"
        // Пока острова нет, звук — единственный сигнал «пишу»: панель
        // меню пользователь в этот момент не открывает.
        if !isPermissionProbe { Self.playTone(start: true) }
        // Стрим стартует только с готовой моделью: если она грузится
        // параллельно, запись всё равно короче загрузки — распознает финал.
        if let buffer, let whisper {
            startStreaming(buffer: buffer, whisper: whisper)
        }
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
        stopStreaming()
        audio?.stopRecording()
        audio?.purgeAudioSamples(keepingLast: 0)
        audio = nil
        targetElement = nil
        targetAppPid = nil
        recordingStartedAt = nil
        // Припаркованный звук тоже отменяется (§5.3: буферы чистятся при
        // отмене) — экран «Загружаю модель…» не должен пережить отмену.
        pendingSamples = nil
        pendingElement = nil
        pendingPid = nil
        if isAwaitingModel {
            isAwaitingModel = false
            if state == .transcribing { state = .idle }
        }
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
        // Тап остановлен — оба буфера стабильны, читать безопасно. Финал
        // всегда по ПОЛНОМУ буферу процессора (ни одна миллисекунда не
        // теряется); разница длин с нашей стрим-копией — точная длина
        // «головы», долетевшей до установки колбэка внутри
        // startRecordingLive: на неё сдвигается граница подтверждённого,
        // а сама голова дораспознаётся клип-парой в финальном прогоне.
        let captured = streamBuffer?.snapshot() ?? []
        let samples = Array(processor.audioSamples)
        let streamHead: Float = captured.isEmpty ? 0
            : Float(max(0, samples.count - captured.count)) / 16000
        processor.purgeAudioSamples(keepingLast: 0)
        audio = nil
        azaDebugLog("Aza: dictation stopped samples=\(samples.count) captured=\(captured.count) head=\(streamHead)")

        // Короче ~0,3 с — случайное нажатие, распознавать нечего.
        guard samples.count > 4800 else {
            stopStreaming()
            state = .idle
            status = "Слишком короткая запись"
            targetElement = nil
            targetAppPid = nil
            applyPendingProfileChange()
            return
        }

        guard DictationFilters.hasSpeech(samples) else {
            stopStreaming()
            state = .idle
            status = "Тишина — ничего не распознано"
            targetElement = nil
            targetAppPid = nil
            applyPendingProfileChange()
            azaDebugLog("Aza: dictation skipped, no speech energy")
            return
        }

        state = .transcribing
        recordingStartedAt = nil
        Self.playTone(start: false)
        let element = targetElement
        let pid = targetAppPid
        targetElement = nil
        targetAppPid = nil

        // Модель ещё греется (запись шла параллельно загрузке): звук
        // ждёт её, остров показывает «Загружаю модель…» без волны —
        // распознавание стартует из завершения prepareModel.
        guard let whisper else {
            // Модели не было — стрим и не стартовал; чистим защитно.
            stopStreaming()
            // Загрузчик мог упасть ещё до отпускания клавиши — тогда
            // паркинг ждал бы вечно. Пробуем поднять заново; не вышло
            // (повторный сбой, модель удалена) — честный idle.
            if !isLoadingModel { prepareModel(ownsState: false) }
            guard isLoadingModel else {
                state = .idle
                status = "Модель не загрузилась — звук не распознан"
                applyPendingProfileChange()
                azaDebugLog("Aza: dictation dropped samples, no model loader")
                return
            }
            pendingSamples = samples
            pendingElement = element
            pendingPid = pid
            isAwaitingModel = true
            status = "Загружаю модель распознавания…"
            azaDebugLog("Aza: dictation samples parked awaiting model")
            return
        }
        status = "Распознаю…"
        // Стрим передаётся финальному распознаванию: оно дождётся его
        // текущего прохода и допишет только неподтверждённый хвост.
        let stream = streamTask
        streamTask = nil
        transcribe(samples: samples, whisper: whisper, element: element,
                   targetPid: pid, stream: stream, streamHead: streamHead)
    }

    /// Распознавание готовых сэмплов: общий хвост для «модель уже была» и
    /// «звук дождался модели».
    private func transcribe(samples: [Float], whisper: WhisperKit,
                            element: AXUIElement?, targetPid: pid_t?,
                            stream: Task<Void, Never>? = nil,
                            streamHead: Float = 0) {
        Task { [weak self] in
            guard let self else { return }
            // Прогрев ещё идёт — дожидаемся: два одновременных прогона
            // на одном экземпляре WhisperKit не нужны.
            await self.warmupTask?.value
            // Стрим: отменяем цикл и ждём его текущий проход (тот держит
            // модель), затем забираем подтверждённое.
            await self.awaitRetiredModelWork()
            var confirmed: [(text: String, avgLogprob: Float, noSpeechProb: Float)] = []
            var clipStart: Float = 0
            var streamedLanguage: String?
            if let stream {
                stream.cancel()
                await stream.value
                confirmed = self.streamSegments
                clipStart = self.streamConfirmedEnd
                streamedLanguage = self.streamLanguage
                self.streamSegments = []
                self.streamConfirmedEnd = 0
                self.streamLanguage = nil
                self.streamBuffer = nil
            }
            azaDebugLog("Aza: dictation transcribe begin streamed=\(confirmed.count) clip=\(clipStart)")
            do {
                // §5.2: русский, английский или автоопределение между ними.
                let language: String
                var results: [TranscriptionResult]
                let prompt = Self.promptTokens(for: whisper)

                if clipStart > 0 {
                    // Стрим работал (значит, язык явный): финалим только
                    // неподтверждённый хвост — ЯЗЫКОМ СТРИМА, а не живой
                    // настройкой: её могли сменить посреди записи.
                    // Голова (streamHead — звук до установки колбэка, стрим
                    // её не видел) дораспознаётся клип-парой [0, head] в том
                    // же прогоне; подтверждённая граница сдвигается на head:
                    // таймстемпы стрима шли по копии без головы.
                    language = streamedLanguage ?? Self.preferredLanguage
                    // Ни в хвосте, ни в голове нет речи (типовой случай:
                    // договорили, выдохнули, отпустили) — финальный прогон
                    // не нужен вовсе, текст уже подтверждён стримом.
                    let boundary = min(samples.count, Int((streamHead + clipStart) * 16000))
                    let headEnd = min(samples.count, Int(streamHead * 16000))
                    let tailSilent = !DictationFilters.hasSpeech(Array(samples[boundary...]))
                    let headSilent = streamHead <= 0
                        || !DictationFilters.hasSpeech(Array(samples[..<headEnd]))
                    if tailSilent, headSilent, !confirmed.isEmpty {
                        azaDebugLog("Aza: dictation final pass skipped, silent tail")
                        self.activeLanguage = language
                        let text = Self.finishText(segments: confirmed)
                        self.finish(text: text, language: language,
                                    element: element, targetPid: targetPid)
                        return
                    }
                    var options = Self.options(for: language, prompt: prompt)
                    options.clipTimestamps = streamHead > 0
                        ? [0, streamHead, streamHead + clipStart]
                        : [clipStart]
                    // Дефолтный windowClipTime 1.0 не заходит в клипы короче
                    // секунды: пропали бы и голова (~0,1–0,4 с), и подсекундный
                    // ХВОСТ (последние слова после подтверждённой границы).
                    // Риск лишнего окна на самом краю гасит фильтр reliableText.
                    options.windowClipTime = 0.05
                    options.chunkingStrategy = nil
                    results = try await whisper.transcribe(
                        audioArray: samples, decodeOptions: options)
                } else if Self.preferredLanguage == "auto" {
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
                let segments = results.flatMap(\.segments)
                // Хронология текста: сегменты головы (до streamHead, стрим их
                // не видел) — ПЕРЕД подтверждёнными, хвост — после. Таймстемпы
                // Whisper абсолютные, граница с допуском на округление.
                let boundary = streamHead + 0.1
                let splitByHead = clipStart > 0 && streamHead > 0
                let head = splitByHead ? segments.filter { $0.end <= boundary } : []
                let tail = splitByHead ? segments.filter { $0.end > boundary } : segments
                func tuples(_ list: [TranscriptionSegment])
                    -> [(text: String, avgLogprob: Float, noSpeechProb: Float)] {
                    list.map { (text: $0.text, avgLogprob: $0.avgLogprob,
                                noSpeechProb: $0.noSpeechProb) }
                }
                let text = Self.finishText(segments: tuples(head) + confirmed + tuples(tail))
                self.finish(text: text, language: language,
                            element: element, targetPid: targetPid)
            } catch {
                self.state = .idle
                self.status = "Распознавание не удалось: \(error.localizedDescription)"
                self.applyPendingProfileChange()
                azaDebugLog("Aza: dictation transcribe failed")
            }
        }
    }

    private func finish(text: String, language: String,
                        element: AXUIElement?, targetPid: pid_t?) {
        state = .idle
        guard !text.isEmpty else {
            status = "Ничего не распознано"
            applyPendingProfileChange()
            return
        }
        azaDebugLog("Aza: dictation done lang=\(language) len=\(text.count)")

        // Транскрипт живёт во вкладке «Диктовка», а не в буфере: буфер
        // ниже используется лишь как ТРАНСПОРТ для ⌘V-фолбэков и после
        // вставки возвращается к прежнему содержимому.
        // Персист истории — вне ВСЕХ путей вставки, включая отложенный
        // ⌘V-добив на 180 мс: AES + запись на главном потоке не должны
        // задержать и его. Планируется здесь (до любых ранних выходов —
        // §5.6 сохраняется), выполняется через 250 мс; метка времени —
        // момента диктовки, чтобы копия пользователя в эти 250 мс не
        // оказалась в истории «раньше» транскрипта.
        let store = clipboardStore
        let dictatedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(250)) {
            store()?.add(text: text,
                         sourceAppBundleID: Bundle.main.bundleIdentifier,
                         sourceAppName: "Aza (диктовка)",
                         copiedAt: dictatedAt, isTranscript: true)
        }

        // Вставляем в поле, где курсор СЕЙЧАС, но только если это то же
        // приложение, что и в момент начала записи: так текст не уедет
        // туда, куда пользователь переключился за время распознавания.
        // Идентичность — по pid: сравнивать AX-элементы нельзя (система
        // отдаёт новую обёртку), а когда AX слеп (Electron/webview),
        // элементов нет вовсе — тогда сверяем pid фронтмоста.
        let current = TextInsertion.focusedElement()
        let currentPid = current.flatMap(TextInsertion.processID(of:))
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sameApp = targetPid != nil && targetPid == currentPid
        azaDebugLog("Aza: dictation insert target=\(element == nil ? 0 : 1) current=\(current == nil ? 0 : 1) sameApp=\(sameApp ? 1 : 0)")

        guard sameApp else {
            // Вставлять некуда — буфер не трогаем вовсе: транскрипт уже
            // едет в свою вкладку отложенным персистом выше.
            status = "Транскрипт во вкладке «Диктовка»: \(text.prefix(60))"
            applyPendingProfileChange()
            return
        }

        // Буфер — транспорт для ⌘V-фолбэков: снимаем снимок текущего
        // содержимого, кладём транскрипт и после вставки возвращаем всё
        // как было. TransientType — чтобы чужие менеджеры буфера
        // (стандарт nspasteboard.org) транскрипт тоже не записывали.
        // Монитор своей Aza пропускает запись по ignoredChangeCount:
        // счётчик — из clearContents(), он возвращает НОВОЕ значение
        // атомарно, setString его не меняет.
        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)
        PasteboardMonitor.ignoredChangeCount = pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType:
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let written = pasteboard.changeCount
        // Возврат буфера — после последнего фолбэка (⌘V на 180 мс) с
        // запасом на обработку события целевым приложением. Если за это
        // время буфер менял кто-то другой — не трогаем: его копия новее.
        // ponytail: 600 мс — потолок для медленных Electron; если ⌘V
        // обрабатывается дольше, вставится восстановленное — поднять задержку.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(600)) {
            guard pasteboard.changeCount == written else { return }
            PasteboardMonitor.ignoredChangeCount = pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }

        let inserted: Bool
        let caretBefore = current.flatMap(TextInsertion.caretPosition(of:))
        if let current, !SecureFieldDetector.isSecure(current),
           TextInsertion.isTextLike(current),
           TextInsertion.insert(text, into: current) == .success {
            inserted = true
            // Electron может ответить success, ничего не вставив: каретка
            // обязана сдвинуться. ⌘V — только при точно неподвижной
            // каретке (как в ClipboardCommands): двойная вставка хуже.
            if let caretBefore {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180)) {
                    guard TextInsertion.caretPosition(of: current) == caretBefore else { return }
                    // За 180 мс фокус мог уехать: ⌘V летит в ТЕКУЩЕЕ поле,
                    // поэтому приложение и secure сверяем заново.
                    let focusedNow = TextInsertion.focusedElement()
                    let pidNow = focusedNow.flatMap(TextInsertion.processID(of:))
                        ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
                    guard pidNow == targetPid,
                          focusedNow.map({ !SecureFieldDetector.isSecure($0) }) ?? true
                    else { return }
                    _ = TextInsertion.postPasteCommand()
                }
            }
        } else if let current, SecureFieldDetector.isSecure(current) {
            // Защищённое поле: не вставляем; транскрипт ждёт во вкладке.
            inserted = false
        } else {
            // AX не видит поле или отверг вставку (Claude-чат VS Code,
            // Electron) — текст уже в буфере, добиваем синтетическим ⌘V,
            // как вставка из истории буфера (ClipboardCommands).
            inserted = TextInsertion.postPasteCommand()
            azaDebugLog("Aza: dictation paste fallback ok=\(inserted ? 1 : 0)")
        }
        status = inserted
            ? "Вставлено (\(language)): \(text.prefix(60))"
            : "Транскрипт во вкладке «Диктовка»: \(text.prefix(60))"
        applyPendingProfileChange()
    }

    /// Копия содержимого буфера для возврата после ⌘V-вставки: данные всех
    /// типов переносятся в новые NSPasteboardItem — записанный в буфер item
    /// повторно записать нельзя. Чтение data(forType:) разворачивает
    /// отложенные (promised) данные — цена возврата любых типов, включая
    /// изображения и файлы.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }
}
