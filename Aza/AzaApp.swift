import SwiftUI

@main
struct AzaApp: App {
    @StateObject private var hotKey = GlobalHotKey()
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @StateObject private var clipboardStore: ClipboardStore
    @StateObject private var pasteboardMonitor: PasteboardMonitor

    init() {
        // Второй экземпляр смертельно опасен: у каждого свой монитор слов,
        // и они наперегонки заменяют одно слово — получается «привет привет
        // привет». Эксклюзивный flock race-safe (в отличие от проверки
        // NSRunningApplication), работает и для голого бинарника из
        // DerivedData, а ядро снимает лок при любом выходе процесса.
        let lockPath = ClipboardStore.defaultStorageURL()
            .deletingLastPathComponent()
            .appendingPathComponent("aza.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
        if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
            NSLog("Aza: another instance holds %@, exiting", lockPath)
            exit(0)
        }
        // lockFD намеренно не закрывается — лок держится всю жизнь процесса.
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

