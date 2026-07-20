import AppKit
import SwiftUI

@main
struct KongshanApp: App {
    @NSApplicationDelegateAdaptor(KongshanAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .onAppear { appDelegate.appState = appState }
        } label: {
            Label("kongshan", systemImage: appState.menuBarSymbol)
        }

        Window("kongshan", id: "main") {
            MainWindowView()
                .environment(appState)
                .onAppear { appDelegate.appState = appState }
        }
        .defaultSize(width: 900, height: 620)
    }
}

@MainActor
final class KongshanAppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var preparingToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appState else { return .terminateNow }
        guard !preparingToTerminate else { return .terminateLater }
        preparingToTerminate = true
        Task {
            let safeToTerminate = await appState.prepareForTermination()
            preparingToTerminate = false
            sender.reply(toApplicationShouldTerminate: safeToTerminate)
        }
        return .terminateLater
    }
}
