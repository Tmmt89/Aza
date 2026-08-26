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

    private var hotKey: HotKeyController?
    private var whisper: WhisperKit?
    private var audio: AudioProcessor?
    private var failsafeTimer: Timer?
    /// Поле, сфокусированное в момент старта записи, — вставляем туда же
    /// (перепроверяя secure) после распознавания.
    private var targetElement: AXUIElement?
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
            hotKey = nil
        }
    }

    func stop() {
        hotKey?.stop()
        hotKey = nil
        cancelRecording()
    }

    // MARK: Жизненный цикл записи

    private func keyDown() {
        guard state == .idle else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            // Первый запрос разрешения: возвращаемся в idle — пользователь
            // удержит клавишу заново уже с выданным доступом.
            status = "Разрешите доступ к микрофону и удержите ⌃⇧D ещё раз"
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor [weak self] in
                    self?.status = granted
                        ? "Доступ к микрофону есть — удержите ⌃⇧D"
                        : "Доступ к микрофону запрещён (Настройки → Конфиденциальность)"
                }
            }
            return
        default:
            status = "Нет доступа к микрофону (Настройки → Конфиденциальность)"
            return
        }

        guard whisper != nil else {
            prepareModel()
            return
        }

        beginRecording()
    }

    private func prepareModel() {
        state = .loadingModel("0%")
        status = "Загрузка модели распознавания…"
        Task { [weak self] in
            do {
                let folder = try await WhisperKit.download(
                    variant: Self.modelVariant,
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
                let whisper = try await WhisperKit(modelFolder: folder.path, load: true)
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
        targetElement = TextInsertion.focusedElement()
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
        status = "Запись… отпустите ⌃⇧D, чтобы вставить текст"
        failsafeTimer = Timer.scheduledTimer(withTimeInterval: Self.maxRecordingSeconds,
                                             repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.status = "Достигнут предел 30 минут — останавливаю"
                self?.keyUp()
            }
        }
        azaDebugLog("Aza: dictation recording started")
    }

    private func cancelRecording() {
        failsafeTimer?.invalidate()
        failsafeTimer = nil
        audio?.stopRecording()
        audio?.purgeAudioSamples(keepingLast: 0)
        audio = nil
        targetElement = nil
        state = .idle
    }

    private func keyUp() {
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
            guard let self, let whisper = self.whisper else { return }
            do {
                // §5.2: только ru/en — выбираем явно по вероятностям,
                // а не общий автодетект по всем языкам Whisper.
                let detected = try await whisper.detectLangauge(audioArray: samples)
                let probs = detected.langProbs
                let language = (probs["ru"] ?? 0) >= (probs["en"] ?? 0) ? "ru" : "en"
                let options = DecodingOptions(task: .transcribe,
                                              language: language,
                                              usePrefillPrompt: true)
                let results = try await whisper.transcribe(audioArray: samples,
                                                           decodeOptions: options)
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
