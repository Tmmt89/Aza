import Carbon.HIToolbox

/// Registers one global hot key (⌘⇧A) via Carbon. Owner must call stop().
@MainActor
final class HotKeyController {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let onActivation: () -> Void

    init(onActivation: @escaping () -> Void) {
        self.onActivation = onActivation
    }

    /// Returns nil on success, otherwise the failing OSStatus.
    func register() -> OSStatus? {
        var event = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, context in
                guard let context else { return noErr }
                let controller = Unmanaged<HotKeyController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated {
                    controller.onActivation()
                }
                return noErr
            },
            1,
            &event,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )

        guard handlerStatus == noErr else { return handlerStatus }

        let hotKeyID = EventHotKeyID(signature: 0x415A_4131, id: 1) // AZA1
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )

        return hotKeyStatus == noErr ? nil : hotKeyStatus
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
