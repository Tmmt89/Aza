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

    @Published private(set) var state: State = .idle
    @Published private(set) var status = "Диктовка: удерживайте ⌃⇧D"

    /// Модель MVP: одна, multilingual small — терпимый русский при ~500 МБ.
    /// Выбор из трёх профилей (§5.4) появится вместе с онбордингом.
    static let modelVariant = "openai_whisper-small"

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
    /// Режим фиксации (спецификация §5.1, «двойное нажатие»): запись
    /// продолжается после отпускания клавиши до повторного нажатия.
    private var isLatched = false
    private var lastPressAt = Date.distantPast
    /// Второе нажатие в пределах этого окна включает фиксацию.
    private static let doubleTapWindow: TimeInterval = 0.5
    /// История буфера для транскриптов (§5.6); появляется асинхронно.
    private let clipboardStore: () -> ClipboardStore?

    init(clipboardStore: @escaping () -> ClipboardStore?) {
        self.clipboardStore = clipboardStore
    }

    func start() {
        guard hotKey == nil else { return }
        let controller = HotKeyController(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(controlKey | shiftKey),
            id: 2,
            onPress: { [weak self] in self?.keyDown() },
            onRelease: { [weak self] in self?.keyUp() }
        )
        hotKey = controller
        if let status = controller.register() {
            self.status = "Горячая клавиша диктовки недоступна (\(status))"
            azaDebugLog("Aza: dictation hotkey registration FAILED status=\(status)")
            hotKey = nil
        } else {
            azaDebugLog("Aza: dictation hotkey registered (ctrl+shift+D)")
        }
    }

    func stop() {
        hotKey?.stop()
        hotKey = nil
        cancelRecording()
    }

    // MARK: Жизненный цикл записи

    private func keyDown() {
        azaDebugLog("Aza: dictation keyDown state=\(state) latched=\(isLatched ? 1 : 0)")

        // Нажатие во время зафиксированной записи останавливает её
        // (спецификация §5.1). Space/Enter как альтернативные стопы
        // отложены: их подавление требует перехвата ввода.
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
                status = "Запись зафиксирована — нажмите ⌃⇧D, чтобы остановить"
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
            status = "Разрешите доступ к микрофону и удержите ⌃⇧D ещё раз"
            isPermissionProbe = true
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    azaDebugLog("Aza: dictation mic request granted=\(granted ? 1 : 0)")
                    self.cancelRecording()
                    self.isPermissionProbe = false
                    self.status = granted
                        ? "Доступ к микрофону есть — удержите ⌃⇧D и говорите"
                        : "Доступ к микрофону запрещён — откройте Настройки → Конфиденциальность → Микрофон"
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
            prepareModel()
            return
        }

        beginRecording()
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
        state = .loadingModel("0%")
        status = "Загрузка модели распознавания…"
        Task { [weak self] in
            do {
                let folder = try await WhisperKit.download(
                    variant: Self.modelVariant,
                    downloadBase: Self.modelStorageDirectory,
                    progressCallback: { progress in
                        Task { @MainActor [weak self] in
                            // Колбэк прогресса приходит асинхронно и может
                            // опоздать: обновляем только пока грузимся,
                            // иначе вернули бы idle обратно в loadingModel.
                            guard let self, case .loadingModel = self.state else { return }
                            let percent = Int(progress.fractionCompleted * 100)
                            self.state = .loadingModel("\(percent)%")
                            self.status = "Загрузка модели: \(percent)%"
                        }
                    }
                )
                // tokenizerFolder — тоже корень кэша: токенизатор качается
                // отдельно от модели и иначе снова уедет в ~/Documents.
                let whisper = try await WhisperKit(
                    modelFolder: folder.path,
                    tokenizerFolder: Self.modelStorageDirectory,
                    load: true
                )
                guard let self else { return }
                self.whisper = whisper
                self.state = .idle
                self.status = "Модель готова — удерживайте ⌃⇧D и говорите"
                azaDebugLog("Aza: dictation model loaded")
            } catch {
                guard let self else { return }
                self.state = .idle
                self.status = "Модель не загрузилась: \(error.localizedDescription)"
                azaDebugLog("Aza: dictation model load failed")
            }
        }
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
        status = isLatched
            ? "Запись зафиксирована — нажмите ⌃⇧D, чтобы остановить"
            : "Запись… отпустите ⌃⇧D, чтобы вставить текст"
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
            return
        }

        state = .transcribing
        status = "Распознаю…"
        let element = targetElement
        targetElement = nil

        Task { [weak self] in
            guard let self, let whisper = self.whisper else {
                azaDebugLog("Aza: dictation transcribe skipped (no self/model)")
                return
            }
            azaDebugLog("Aza: dictation transcribe begin")
            do {
                // §5.2: только ru/en — выбираем явно по вероятностям,
                // а не общий автодетект по всем языкам Whisper.
                let detected = try await whisper.detectLangauge(audioArray: samples)
                let probs = detected.langProbs
                let language = (probs["ru"] ?? 0) >= (probs["en"] ?? 0) ? "ru" : "en"
                azaDebugLog("Aza: dictation language=\(language)")
                let options = DecodingOptions(task: .transcribe,
                                              language: language,
                                              usePrefillPrompt: true)
                let results = try await whisper.transcribe(audioArray: samples,
                                                           decodeOptions: options)
                azaDebugLog("Aza: dictation transcribe results=\(results.count)")
                let text = results.map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.finish(text: text, language: language, element: element)
            } catch {
                self.state = .idle
                self.status = "Распознавание не удалось: \(error.localizedDescription)"
                azaDebugLog("Aza: dictation transcribe failed")
            }
        }
    }

    private func finish(text: String, language: String, element: AXUIElement?) {
        state = .idle
        guard !text.isEmpty else {
            status = "Ничего не распознано"
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

        // Поле должно быть тем же и всё ещё сфокусированным: иначе текст
        // уедет в чужое окно или синтетический ввод напечатает его туда,
        // куда пользователь переключился за время распознавания.
        if let element,
           let current = TextInsertion.focusedElement(),
           CFEqual(current, element),
           !SecureFieldDetector.isSecure(element),
           TextInsertion.isTextLike(element),
           TextInsertion.insert(text, into: element) == .success {
            status = "Вставлено (\(language)): \(text.prefix(60))"
        } else {
            status = "Текст в буфере (⌘V): \(text.prefix(60))"
        }
    }
}
