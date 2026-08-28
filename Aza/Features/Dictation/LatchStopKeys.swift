import AppKit
import Carbon.HIToolbox

/// Пробел и Enter останавливают зафиксированную запись (§5.1). Тап живёт
/// только пока такая запись идёт; стоп-клавиша проглатывается и в активное
/// приложение не попадает — для этого нужен именно CGEvent-tap, слушающий
/// NSEvent-монитор глотать клавиши не умеет. Без Accessibility тап не
/// создаётся — тогда запись, как раньше, останавливают сочетание и кнопки.
@MainActor
final class LatchStopKeys {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let keys = Unmanaged<LatchStopKeys>.fromOpaque(info).takeUnretainedValue()
                // Источник тапа добавлен в main run loop — колбэк приходит
                // на главном потоке.
                return MainActor.assumeIsolated {
                    keys.handle(type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            azaDebugLog("Aza: latch stop tap unavailable (no Accessibility?)")
            return
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        azaDebugLog("Aza: latch stop tap started")
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        azaDebugLog("Aza: latch stop tap stopped")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Система гасит «медленные» тапы сама — включаем обратно.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Только «голые» Пробел и Enter: ⌘Пробел (Spotlight) и прочие
        // сочетания проходят в систему как обычно.
        guard keyCode == kVK_Space || keyCode == kVK_Return,
              event.flags.intersection([.maskCommand, .maskControl,
                                        .maskAlternate, .maskShift]).isEmpty
        else { return Unmanaged.passUnretained(event) }
        // Останавливаем асинхронно: гасить тап из его же колбэка нельзя.
        DispatchQueue.main.async { [onStop] in onStop() }
        return nil
    }
}
