import SwiftUI

@main
struct AzaApp: App {
    @StateObject private var hotKey = GlobalHotKey()

    var body: some Scene {
        MenuBarExtra("Aza", systemImage: "waveform") {
            ContentView(hotKey: hotKey)
        }
        .menuBarExtraStyle(.window)
    }
}
