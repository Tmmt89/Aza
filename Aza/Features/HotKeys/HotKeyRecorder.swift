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
    var onChange: (HotKeyBinding) -> Void

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
                        tint: isRecording ? AzaStyle.acid : AzaStyle.control,
                        prominent: isRecording))
                    .frame(minWidth: 104)

                    // Невидимый перехватчик поверх кнопки — только пока идёт запись.
                    if isRecording {
                        KeyCatcher { event in
                            handle(event)
                        }
                        .frame(width: 104, height: 26)
                        .allowsHitTesting(false)
                    }
                }
            }
            if let problem {
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
        binding = candidate
        onChange(candidate)
        isRecording = false
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
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        // Фокус мог уйти на кнопку — забираем его обратно на каждом
        // обновлении, пока поле в режиме записи.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
    }

    final class CatcherView: NSView {
        var onKey: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        /// Кандидат в одиночные модификаторы: нажатие ⌃ неотличимо от
        /// начала комбинации ⌃⇧D, поэтому модификатор записывается на
        /// ОТПУСКАНИИ — и только если между нажатием и отпусканием не было
        /// ни обычной клавиши, ни второго модификатора (стандарт
        /// ShortcutRecorder / KeyboardShortcuts).
        private var pendingModifier: UInt16?

        override func keyDown(with event: NSEvent) {
            pendingModifier = nil
            onKey?(event)
        }

        override func flagsChanged(with event: NSEvent) {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            if let pending = pendingModifier, event.keyCode == pending,
               let flag = HotKeyBinding.modifierFlagByKeyCode[pending],
               !flags.contains(flag) {
                // Отпустили тот самый модификатор, ничего не нажав, —
                // это и есть выбор. В событии отпускания флагов уже нет,
                // так что carbonModifiers даст 0.
                pendingModifier = nil
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
            onKey?(event)
            return true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }
}
