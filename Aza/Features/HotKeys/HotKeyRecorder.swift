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
        // Без модификатора глобальный хоткей съедал бы обычный набор.
        guard candidate.hasModifier else {
            problem = "Добавьте ⌘, ⌃, ⌥ или ⇧"
            return
        }
        binding = candidate
        onChange(candidate)
        isRecording = false
        problem = nil
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

        override func keyDown(with event: NSEvent) {
            onKey?(event)
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
