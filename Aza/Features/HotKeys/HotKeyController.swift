import Carbon.HIToolbox

/// Registers one global hot key via Carbon with press AND release callbacks
/// (release is what makes hold-to-talk possible). Owner must call stop().
@MainActor
final class HotKeyController {
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
    func register() -> OSStatus? {
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let context, let event else { return noErr }
                var pressedID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
                let kind = GetEventKind(event)
                let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    // Обработчик получает события ВСЕХ хоткеев приложения —
                    // фильтруем по своему id.
                    guard pressedID.id == controller.hotKeyID.id else { return }
                    if kind == UInt32(kEventHotKeyPressed) {
                        controller.onPress()
                    } else if kind == UInt32(kEventHotKeyReleased) {
                        controller.onRelease?()
                    }
                }
                return noErr
            },
            events.count,
            &events,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

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
            // Иначе установленный обработчик переживёт владельца и при
            // следующем событии обратится к освобождённой памяти.
            if let handler {
                RemoveEventHandler(handler)
                self.handler = nil
            }
            return hotKeyStatus
        }
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
    }
}
