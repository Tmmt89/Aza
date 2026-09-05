import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Поле записи горячей клавиши.
///
/// Слушает клавиши НАСТОЯЩИМ NSView, который становится первым
/// респондером: локальный монитор событий сюда не годится — уже
/// зарегистрированный глобальный хоткей перехватывает своё сочетание
/// раньше, и переназначить клавишу на саму себя было невозможно.
struct HotKeyRecorder: View {
    let title: String
    @Binding var binding: HotKeyBinding
    /// Одиночный модификатор (Fn, ⌃, ⌥…) работает только там, где владелец
    /// слушает его монитором (диктовка); остальные хоткеи идут через
    /// Carbon, где модификатор без клавиши молчит.
    var allowModifierKeys = false
    var tint: Color = AzaStyle.rise
    var registrationError: String?
    /// nil означает успешное применение; иначе показываем ошибку и оставляем подпись.
    var onChange: (HotKeyBinding) -> String?

    @State private var isRecording = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                Spacer(minLength: 8)
                ZStack {
                    Button(isRecording ? "Нажмите сочетание" : binding.display) {
                        isRecording.toggle()
                        problem = nil
                    }
                    .buttonStyle(AzaCapsuleButtonStyle(
                        tint: isRecording ? tint : AzaStyle.control,
                        prominent: isRecording))
                    .frame(minWidth: 104)
                    .accessibilityLabel(title)
                    .accessibilityValue(isRecording ? "Ожидаю сочетание" : binding.display)
                    .accessibilityHint("Нажмите, чтобы изменить сочетание. Escape отменяет запись.")

                    // Невидимый перехватчик поверх кнопки — только пока идёт запись.
                    if isRecording {
                        KeyCatcher(onKey: { event in
                            handle(event)
                        }, onCancel: { isRecording = false })
                        .frame(width: 104, height: 26)
                        .allowsHitTesting(false)
                    }
                }
            }
            if let problem = problem ?? registrationError {
                Text(problem)
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.warning)
            }
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            isRecording = false
            return
        }
        let candidate = HotKeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: HotKeyBinding.carbonModifiers(from: event.modifierFlags)
        )
        if candidate.isModifierOnly, !allowModifierKeys {
            isRecording = false
            problem = "Одиночный модификатор доступен только для диктовки"
            return
        }
        isRecording = false
        if let error = onChange(candidate) {
            problem = error
            return
        }
        binding = candidate
        problem = Self.warning(for: candidate)
    }

    /// Не запрет, а честное описание побочного эффекта выбранной клавиши.
    private static func warning(for binding: HotKeyBinding) -> String? {
        if binding.isModifierOnly {
            switch Int(binding.keyCode) {
            case kVK_Function:
                return "Если 🌐 открывает Эмодзи или меняет раскладку, выключите это: Настройки macOS → Клавиатура → «При нажатии 🌐» → «Ничего не делать»"
            case kVK_RightOption:
                return "Правая ⌥ уже открывает панель фраз — выберите другую клавишу, если пользуетесь фразами"
            case kVK_Control, kVK_Option, kVK_Shift, kVK_Command:
                // Левые модификаторы живут во всех сочетаниях: ⌃C, ⌥Tab…
                // Каждое начнётся с запуска записи. Правые — почти нет.
                return "Клавиша участвует в сочетаниях — каждое будет коротко запускать запись. Fn или правый модификатор надёжнее"
            default:
                return nil
            }
        }
        // Одиночная клавиша разрешена (удобно для F-клавиш), но у
        // буквенных это отнимает символ у всех приложений — предупреждаем.
        return binding.hasModifier
            ? nil
            : "Без модификатора клавиша перестанет печатать свой символ во всех приложениях"
    }
}

/// NSView, который забирает фокус и отдаёт нажатия наружу.
struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Void
    let onCancel: () -> Void

    /// Tap передаёт записываемые клавиши сюда ДО команд окна (⌘W/⌘Q).
    static func forward(_ cgEvent: CGEvent, to window: NSWindow?) -> Bool {
        guard let recorder = CatcherView.current else { return false }
        guard let window, window.isVisible, recorder.window === window,
              window.firstResponder === recorder else {
            recorder.cancel()
            return false
        }
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        // Переключение приложения отменяет запись, как потеря фокуса мышью.
        if event.keyCode == UInt16(kVK_Tab), event.modifierFlags.contains(.command) {
            recorder.cancel()
            return false
        }
        RunLoop.main.perform(inModes: [.common]) { [weak recorder] in
            azaAssumeMainUnchecked {
                guard let recorder, CatcherView.current === recorder else { return }
                switch event.type {
                case .keyDown: recorder.keyDown(with: event)
                case .flagsChanged: recorder.flagsChanged(with: event)
                default: break
                }
            }
        }
        return true
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        view.onCancel = onCancel
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.endRecording()
        view.stopObserving()
    }

    final class CatcherView: NSView {
        private(set) static weak var current: CatcherView?
        var onKey: ((NSEvent) -> Void)?
        var onCancel: (() -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var activationObserver: NSObjectProtocol?

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            if Self.current !== self { Self.current?.cancel() }
            Self.current = self
            HotKeyController.isRecordingShortcut = true
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            cancel()
            return true
        }

        func endRecording() {
            guard Self.current === self else { return }
            Self.current = nil
            HotKeyController.isRecordingShortcut = false
            pendingModifier = nil
        }

        func cancel() {
            guard Self.current === self else { return }
            endRecording()
            let onCancel = onCancel
            DispatchQueue.main.async { onCancel?() }
        }

        func stopObserving() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            if let activationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
                self.activationObserver = nil
            }
        }

        /// Кандидат в одиночные модификаторы: нажатие ⌃ неотличимо от
        /// начала комбинации ⌃⇧D, поэтому модификатор записывается на
        /// ОТПУСКАНИИ — и только если между нажатием и отпусканием не было
        /// ни обычной клавиши, ни второго модификатора (стандарт
        /// ShortcutRecorder / KeyboardShortcuts).
        private var pendingModifier: UInt16?

        override func keyDown(with event: NSEvent) {
            guard Self.current === self else { return }
            endRecording()
            onKey?(event)
        }

        override func flagsChanged(with event: NSEvent) {
            guard Self.current === self else { return }
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            if let pending = pendingModifier, event.keyCode == pending,
               let flag = HotKeyBinding.modifierFlagByKeyCode[pending],
               !flags.contains(flag) {
                // Отпустили тот самый модификатор, ничего не нажав, —
                // это и есть выбор. В событии отпускания флагов уже нет,
                // так что carbonModifiers даст 0.
                endRecording()
                onKey?(event)
                return
            }
            // Нажат ровно один модификатор — кандидат; всё остальное
            // (второй модификатор сверху, отпускание чужого) сбрасывает.
            if let flag = HotKeyBinding.modifierFlagByKeyCode[event.keyCode],
               flags == flag {
                pendingModifier = event.keyCode
            } else {
                pendingModifier = nil
            }
        }

        /// Сочетания вроде ⌘V система сначала предлагает как «эквивалент
        /// меню» — перехватываем и здесь, иначе они до keyDown не дойдут.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard Self.current === self, event.type == .keyDown else { return false }
            keyDown(with: event)
            return true
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            cancel()
            stopObserving()
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSApplication.didResignActiveNotification] {
                let object: Any? = name == NSApplication.didResignActiveNotification ? nil : window
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: object, queue: .main) { [weak self] _ in
                        azaAssumeMainUnchecked { self?.cancel() }
                    })
            }
            // Tap может вести фокус, пока NSApp.isActive == false.
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                azaAssumeMainUnchecked { self?.cancel() }
            }
            window.makeFirstResponder(self)
        }
    }
}
