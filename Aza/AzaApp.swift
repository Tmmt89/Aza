import SwiftUI

@main
struct AzaApp: App {
    @StateObject private var hotKey = GlobalHotKey()
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @StateObject private var clipboardStore: ClipboardStore
    @StateObject private var pasteboardMonitor: PasteboardMonitor

    init() {
        let store = ClipboardStore()
        _clipboardStore = StateObject(wrappedValue: store)
        let monitor = PasteboardMonitor(store: store)
        _pasteboardMonitor = StateObject(wrappedValue: monitor)
        if PasteboardMonitor.historyEnabledByDefault {
            monitor.start()
        }
    }

    var body: some Scene {
        MenuBarExtra("Aza", systemImage: "waveform") {
            ContentView(
                hotKey: hotKey,
                clipboardStore: clipboardStore,
                pasteboardMonitor: pasteboardMonitor
            )
        }
        .menuBarExtraStyle(.window)
        .onChange(of: clipboardHistoryEnabled) { _, isEnabled in
            if isEnabled {
                pasteboardMonitor.start()
            } else {
                pasteboardMonitor.stop()
            }
        }
    }
}

