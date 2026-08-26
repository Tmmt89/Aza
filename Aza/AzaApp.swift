import Combine
import SwiftUI

/// Асинхронный старт хранилища буфера: ключ Keychain добывается на фоне,
/// потому что SecItemCopyMatching может показать модальный диалог
/// (разблокировка связки, подтверждение доступа) — на главном потоке он
/// дважды вешал ВСЁ приложение, включая коррекцию раскладки. Пока ключ
/// не получен, панель показывает «история загружается», а коррекция
/// работает с первой секунды.
@MainActor
final class ClipboardStartup: ObservableObject {
    @Published private(set) var store: ClipboardStore?
    @Published private(set) var monitor: PasteboardMonitor?

    init() {
        DispatchQueue.global(qos: .userInitiated).async {
            let prepared = ClipboardStore.obtainKey()
            DispatchQueue.main.async {
                let store = ClipboardStore(preparedKey: prepared)
                let monitor = PasteboardMonitor(store: store)
                self.store = store
                self.monitor = monitor
                if PasteboardMonitor.historyEnabledByDefault {
                    monitor.start()
                }
#if DEBUG
                ClipboardStore.runSelfTest(sample: "буфер-самотест-\(UUID().uuidString)")
#endif
            }
        }
    }

    func setMonitoring(enabled: Bool) {
        guard let monitor else { return }
        if enabled {
            monitor.start()
        } else {
            monitor.stop()
        }
    }
}

@main
struct AzaApp: App {
    @StateObject private var hotKey = GlobalHotKey()
    @AppStorage(PasteboardMonitor.storageKey) private var clipboardHistoryEnabled = true
    @StateObject private var clipboardStartup: ClipboardStartup

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
        _clipboardStartup = StateObject(wrappedValue: ClipboardStartup())
    }

    var body: some Scene {
        MenuBarExtra("Aza", systemImage: "waveform") {
            ContentView(hotKey: hotKey, clipboardStartup: clipboardStartup)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: clipboardHistoryEnabled) { _, isEnabled in
            clipboardStartup.setMonitoring(enabled: isEnabled)
        }
    }
}
