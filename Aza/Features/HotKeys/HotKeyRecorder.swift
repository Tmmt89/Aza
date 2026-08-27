import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Поле записи горячей клавиши: нажмите — и введите сочетание.
///
/// Используется локальный монитор событий, а не onKeyPress: нужны коды
/// клавиш и модификаторы «как есть», без раскладочной трансляции.
struct HotKeyRecorder: View {
    let title: String
    @Binding var binding: HotKeyBinding
    var onChange: (HotKeyBinding) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(AzaStyle.body)
                    .foregroundStyle(AzaStyle.ink)
                Spacer(minLength: 8)
                Button(isRecording ? "Нажмите сочетание…" : binding.display) {
                    isRecording ? stop() : start()
                }
                .buttonStyle(AzaCapsuleButtonStyle(
                    tint: isRecording ? AzaStyle.acid : AzaStyle.control,
                    prominent: isRecording))
                .frame(minWidth: 92)
            }
            if let problem {
                Text(problem)
                    .font(AzaStyle.caption)
                    .foregroundStyle(AzaStyle.warning)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        problem = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc отменяет запись, не назначая клавишу.
            guard event.keyCode != UInt16(kVK_Escape) else {
                stop()
                return nil
            }
            let candidate = HotKeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: HotKeyBinding.carbonModifiers(from: event.modifierFlags)
            )
            // Без модификатора глобальный хоткей съедал бы обычный набор.
            guard candidate.hasModifier else {
                problem = "Добавьте модификатор: ⌘, ⌃, ⌥ или ⇧"
                return nil
            }
            binding = candidate
            onChange(candidate)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
