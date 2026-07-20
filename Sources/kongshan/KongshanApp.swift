import SwiftUI

@main
struct KongshanApp: App {
    var body: some Scene {
        MenuBarExtra("kongshan", systemImage: "shield.slash") {
            MenuBarView()
        }

        Window("kongshan", id: "main") {
            MainWindowView()
        }
        .defaultSize(width: 900, height: 620)
    }
}
