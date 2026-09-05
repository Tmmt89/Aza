import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem

/// Системное выделение области получает весь ввод, даже над окнами Aza.
/// Проверяем экранный слой, а не жизнь процесса: после снимка остаётся
/// маленькая миниатюра, которая не должна блокировать работу приложения.
enum SystemScreenCapture {
    @MainActor
    static var isSelecting: Bool {
        // screencaptureui не обязан регистрироваться как NSRunningApplication.
        guard let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return hasSelectionOverlay(in: windows,
                                   screenSizes: NSScreen.screens.map { $0.visibleFrame.size })
    }

    static func hasSelectionOverlay(in windows: [[String: Any]],
                                    screenSizes: [CGSize]) -> Bool {
        windows.contains { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String,
                  owner == "screencaptureui" || owner == "screencapture",
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { return false }
            // ponytail: геометрия штатного полноэкранного слоя; заменить
            // проверкой сессии, если macOS предоставит публичный API.
            return screenSizes.contains { $0.width > 0 && $0.height > 0
                && width >= $0.width && height >= $0.height }
        }
    }
}

/// Registers one global hot key via Carbon with press AND release callbacks
/// (release is what makes hold-to-talk possible). Owner must call stop().
///
/// Carbon работает без Accessibility. CGEventTap острова дополняет его
/// на системах с проблемной доставкой AppKit; общий pressed убирает дубли.
@MainActor
final class HotKeyController {
    private static var active: [HotKeyController] = []
    /// Записываемое сочетание должно дойти до KeyCatcher вместо запуска команды.
    static var isRecordingShortcut = false

    /// Вызов из CGEventTap. true — событие было хоткеем и обработано
    /// (глотаем, как глотал Carbon). Автоповторы подавляются флагом
    /// pressed. keyUp матчится по одной клавише среди нажатых:
    /// модификаторы к моменту отпускания часто уже брошены, и точное
    /// сравнение теряло бы release hold-хоткеев.
    static func handleTapKey(keyCode: UInt32, carbonModifiers: UInt32,
                             isDown: Bool, sourceUserData: Int64 = 0) -> Bool {
        guard sourceUserData != TextInsertion.syntheticEventMarker else { return false }
        guard !isRecordingShortcut else {
            // Отпускания во время записи не должны оставлять старый хоткей зажатым.
            if !isDown {
                for controller in active where controller.pressed && controller.keyCode == keyCode {
                    controller.deliver(isDown: false)
                }
            }
            return false
        }
        var handled = false
        for controller in active {
            if isDown {
                guard controller.keyCode == keyCode,
                      controller.modifiers == carbonModifiers else { continue }
                controller.deliver(isDown: true)
                handled = true
            } else if controller.pressed, controller.keyCode == keyCode {
                controller.deliver(isDown: false)
                handled = true
            }
        }
        return handled
    }

    /// Действие — вне колбэка tap'а: переход острова (пересборка SwiftUI-
    /// панели) внутри колбэка — работа на десятки миллисекунд под
    /// таймаутом tap'а (превышение = macOS отключает tap, и keyUp
    /// hold-хоткея проскакивает мимо). Блок runloop в common modes, а не
    /// main queue: очередь в tracking-петлях AppKit не дренируется.
    private func deferred(_ action: @escaping () -> Void) {
        let generation = generation
        RunLoop.main.perform(inModes: [.common]) { [self] in
            azaAssumeMainUnchecked {
                guard self.generation == generation, self.hotKey != nil else { return }
                action()
            }
        }
    }

    private var generation: UInt = 0
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

    private func deliver(isDown: Bool) {
        guard pressed != isDown else { return }
        pressed = isDown
        if isDown {
            deferred(onPress)
        } else if let onRelease {
            deferred(onRelease)
        }
    }

    /// Прежний интерфейс: ⌘⇧A только по нажатию.
    convenience init(onActivation: @escaping () -> Void) {
        self.init(keyCode: UInt32(kVK_ANSI_A),
                  modifiers: UInt32(cmdKey | shiftKey),
                  id: 1,
                  onPress: onActivation)
    }

    /// Returns nil on success, otherwise the failing OSStatus.
    func register() -> OSStatus? {
        guard hotKey == nil else { return nil }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            if let input = CopyEventCGEvent(event)?.takeRetainedValue(),
               input.getIntegerValueField(.eventSourceUserData) == TextInsertion.syntheticEventMarker {
                return OSStatus(eventNotHandledErr)
            }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                    EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr
            else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
            return azaAssumeMainUnchecked {
                guard id.signature == controller.hotKeyID.signature,
                      id.id == controller.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                let isDown = GetEventKind(event) == kEventHotKeyPressed
                if !HotKeyController.isRecordingShortcut || !isDown { controller.deliver(isDown: isDown) }
                return noErr
            }
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard handlerStatus == noErr else { return handlerStatus }
        let hotKeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return hotKeyStatus
        }
        Self.active.append(self)
        return nil
    }

    func stop() {
        generation &+= 1
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
    private static let physicalFlags: [UInt16: UInt] = [
        UInt16(kVK_Control): UInt(NX_DEVICELCTLKEYMASK),
        UInt16(kVK_RightControl): UInt(NX_DEVICERCTLKEYMASK),
        UInt16(kVK_Shift): UInt(NX_DEVICELSHIFTKEYMASK),
        UInt16(kVK_RightShift): UInt(NX_DEVICERSHIFTKEYMASK),
        UInt16(kVK_Option): UInt(NX_DEVICELALTKEYMASK),
        UInt16(kVK_RightOption): UInt(NX_DEVICERALTKEYMASK),
        UInt16(kVK_Command): UInt(NX_DEVICELCMDKEYMASK),
        UInt16(kVK_RightCommand): UInt(NX_DEVICERCMDKEYMASK),
        UInt16(kVK_Function): UInt(NX_SECONDARYFNMASK),
    ]
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

    func register(accessibilityGranted: Bool = AXIsProcessTrusted()) -> OSStatus? {
        guard accessibilityGranted else {
            stop()
            return OSStatus(permErr)
        }
        guard monitors.isEmpty else { return nil }
        let handle: (NSEvent) -> Void = { [weak self] event in
            azaAssumeMainUnchecked { self?.handle(event) }
        }
        guard let global = NSEvent.addGlobalMonitorForEvents(
            matching: .flagsChanged, handler: handle) else {
            return OSStatus(eventInternalErr)
        }
        guard let local = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged, handler: { handle($0); return $0 }) else {
            NSEvent.removeMonitor(global)
            return OSStatus(eventInternalErr)
        }
        monitors = [global, local]
        return nil
    }

    func handle(_ event: NSEvent) {
        // Общий .control/.shift остаётся включённым, пока зажата другая
        // сторона. Отпускание своей клавиши проверяем по физическому флагу.
        let physicallyHeld = event.modifierFlags.rawValue & (Self.physicalFlags[keyCode] ?? 0) != 0
        if held {
            if !physicallyHeld {
                held = false
                onRelease?()
            }
            return
        }
        guard event.keyCode == keyCode, physicallyHeld else { return }
        // Caps Lock — состояние, а не удерживаемый модификатор (см.
        // правую ⌥ в IslandStore).
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard !HotKeyController.isRecordingShortcut,
              !SystemScreenCapture.isSelecting, flags == flag else { return }
        held = true
        onPress()
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if held {
            held = false
            onRelease?()
        }
    }
}
