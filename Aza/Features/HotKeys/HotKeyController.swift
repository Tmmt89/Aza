import AppKit
import Carbon.HIToolbox

/// Registers one global hot key via Carbon with press AND release callbacks
/// (release is what makes hold-to-talk possible). Owner must call stop().
///
/// Сами нажатия матчит CGEventTap острова через handleTapKey: Carbon-
/// диспетчер process target на этой macOS мёртв — события гибнут между
/// CG-очередью и приложением (см. память aza-island-clicks), его колбэк
/// не вызывается. RegisterEventHotKey остаётся ради системной
/// эксклюзивности сочетания и честной детекции конфликтов.
@MainActor
final class HotKeyController {
    private static var active: [HotKeyController] = []

    /// Вызов из CGEventTap. true — событие было хоткеем и обработано
    /// (глотаем, как глотал Carbon). Автоповторы подавляются флагом
    /// pressed. keyUp матчится по одной клавише среди нажатых:
    /// модификаторы к моменту отпускания часто уже брошены, и точное
    /// сравнение теряло бы release hold-хоткеев.
    static func handleTapKey(keyCode: UInt32, carbonModifiers: UInt32,
                             isDown: Bool) -> Bool {
        var handled = false
        for controller in active {
            if isDown {
                guard controller.keyCode == keyCode,
                      controller.modifiers == carbonModifiers else { continue }
                if !controller.pressed {
                    controller.pressed = true
                    controller.onPress()
                }
                handled = true
            } else if controller.pressed, controller.keyCode == keyCode {
                controller.pressed = false
                controller.onRelease?()
                handled = true
            }
        }
        return handled
    }

    private var pressed = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let hotKeyID: EventHotKeyID
    private let onPress: () -> Void
    private let onRelease: (() -> Void)?

    /// - Parameters:
    ///   - id: уникален в пределах приложения (Carbon различает хоткеи по нему).
    init(keyCode: UInt32, modifiers: UInt32, id: UInt32,
         onPress: @escaping () -> Void, onRelease: (() -> Void)? = nil) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyID = EventHotKeyID(signature: 0x415A_4131, id: id) // AZA1
        self.onPress = onPress
        self.onRelease = onRelease
    }

    /// Прежний интерфейс: ⌘⇧A только по нажатию.
    convenience init(onActivation: @escaping () -> Void) {
        self.init(keyCode: UInt32(kVK_ANSI_A),
                  modifiers: UInt32(cmdKey | shiftKey),
                  id: 1,
                  onPress: onActivation)
    }

    /// Returns nil on success, otherwise the failing OSStatus.
    /// Carbon-обработчик не ставится — его диспетчер мёртв, нажатия
    /// приходят из CGEventTap через handleTapKey.
    func register() -> OSStatus? {
        let hotKeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr else { return hotKeyStatus }
        Self.active.append(self)
        return nil
    }

    func stop() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        pressed = false
        Self.active.removeAll { $0 === self }
    }
}

/// Одиночная клавиша-модификатор (Fn, ⌃, ⌥, ⇧, ⌘) как хоткей. Модификаторы
/// не дают keyDown и Carbon их не регистрирует, поэтому слушаем flagsChanged —
/// тот же механизм, что у правой ⌥ в IslandStore. Глобальный монитор
/// молчит без Accessibility (приложение и так его запрашивает).
@MainActor
final class ModifierKeyMonitor {
    private var monitors: [Any] = []
    private var held = false
    private let keyCode: UInt16
    private let flag: NSEvent.ModifierFlags
    private let onPress: () -> Void
    private let onRelease: (() -> Void)?

    /// nil, если keyCode — не клавиша-модификатор.
    init?(keyCode: UInt16, onPress: @escaping () -> Void,
          onRelease: (() -> Void)? = nil) {
        guard let flag = HotKeyBinding.modifierFlagByKeyCode[keyCode] else { return nil }
        self.keyCode = keyCode
        self.flag = flag
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func register() {
        guard monitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged, handler: handle) {
            monitors.append(global)
        } else {
            azaDebugLog("Aza: fn global monitor install FAILED (нет Accessibility?)")
        }
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged, handler: { handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == keyCode else { return }
        // Caps Lock — состояние, а не удерживаемый модификатор (см.
        // правую ⌥ в IslandStore).
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if !held {
            // Нажатие засчитываем только «в одиночку»: ⌃ внутри ⌘⌃-комбо
            // не должен запускать диктовку.
            guard flags == flag else { return }
            held = true
            onPress()
        } else if !flags.contains(flag) {
            held = false
            onRelease?()
        }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
    }
}
