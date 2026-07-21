import AppKit
import SwiftUI

@main
struct KongshanApp: App {
    @NSApplicationDelegateAdaptor(KongshanAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appDelegate.appState)
        } label: {
            MenuBarStatusIcon(state: appDelegate.appState)
        }
    }
}

/// 图标放在独立 View 里，让 @Observable 的状态变化在 View body 层被追踪，
/// 而不是依赖 Scene body 重新求值。
private struct MenuBarStatusIcon: View {
    let state: AppState

    var body: some View {
        Image(systemName: state.menuBarSymbol)
    }
}

@MainActor
final class KongshanAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 由 delegate 直接持有，避免依赖某个视图先出现才完成注入；
    /// 否则用户没打开过菜单时 applicationShouldTerminate 会拿不到状态，退出时不还原系统代理。
    let appState = AppState()

    private var mainWindowController: NSWindowController?
    private var preparingToTerminate = false

    /// LSUIElement 应用启动时不会被激活（实测 `isActive=false`、`ppid=1`、
    /// `XPC_SERVICE_NAME` 与登录项同形），因此无法用激活状态或环境变量区分启动来源。
    /// 改用确定信号：开机自启已启用时，冷启动几乎必然来自 launchd 的登录项，保持菜单栏静默常驻；
    /// 其余情况都是用户主动打开，直接展示主窗口。
    /// 自启开启时若用户手动重开应用，再次双击图标会走 reopen 打开窗口。
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            guard await LoginItemManager().currentStatus() != .enabled else { return }
            showMainWindow()
        }
    }

    /// 应用已在运行时再次双击图标，macOS 发送 reopen，此处重新展示主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func showMainWindow() {
        let controller = mainWindowController ?? makeMainWindowController()
        mainWindowController = controller
        // .accessory 策略下应用没有菜单栏，⌘Q/⌘W 与窗口菜单都不可用。
        // 主窗口打开期间切到 .regular（同时出现 Dock 图标），关闭后切回常驻托盘形态。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // 最小化的窗口用 makeKeyAndOrderFront 是唤不出来的，必须先取消最小化，
        // 否则从程序坞点图标没反应。
        if let window = controller.window, window.isMiniaturized {
            window.deminiaturize(nil)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        // 外接屏拔掉后，自动保存的 frame 可能整个落在已消失的屏幕上，
        // 表现为「点了没窗口」。不在任何屏幕上就重新居中。
        if let window = controller.window, window.screen == nil {
            window.center()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !preparingToTerminate else { return .terminateLater }
        preparingToTerminate = true
        Task {
            let safeToTerminate = await appState.prepareForTermination()
            preparingToTerminate = false
            sender.reply(toApplicationShouldTerminate: safeToTerminate)
        }
        return .terminateLater
    }

    private func makeMainWindowController() -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "kongshan"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 880, height: 560)
        // 菜单栏应用关闭窗口后仍需常驻，窗口对象必须留存以便再次打开。
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("kongshan.main")
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: MainWindowView().environment(appState)
        )
        window.center()
        return NSWindowController(window: window)
    }
}
