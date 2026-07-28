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
        HStack(spacing: 4) {
            Image(systemName: state.menuBarSymbol)
            if state.isOn {
                // 速率 0 时用占位符，避免空串导致 label 宽度跳变。
                let dl = MenuRateFormatter.compact(state.downloadRate)
                let ul = MenuRateFormatter.compact(state.uploadRate)
                Text("↓\(dl.isEmpty ? "—" : dl) ↑\(ul.isEmpty ? "—" : ul)")
                    .monospacedDigit()
            }
        }
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
        // SIGPIPE 默认会**直接杀掉进程**。App 会往内核 stdin 的管道里写几百 KB 配置
        // （SingBoxProcess.start / PrivilegedHelperClient.start）；内核若在读完前就退出
        // （端口被占、配置被拒），写端拿到 EPIPE 的同时收到 SIGPIPE → 整个 App 被杀。
        // 全局忽略一次，write 改为返回 -1/EPIPE 由各写入点自行处理。
        signal(SIGPIPE, SIG_IGN)
        // 状态项本身要持续显示速率，因此它是一个常驻监控消费者；仪表盘开关只增减
        // 另一个消费者，不会再把托盘依赖的同一条 WebSocket 误取消。
        appState.startMenuBarMonitoring()
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
        // 在激活之前捕获主屏（菜单栏 / 程序坞所在屏，也就是用户启动时看的那块）。
        // 一旦某个窗口被置为 key，NSScreen.main 会跟着窗口跑，就取不准了。
        let homeScreen = NSScreen.main ?? NSScreen.screens.first
        // .accessory 策略下应用没有菜单栏，⌘Q/⌘W 与窗口菜单都不可用。
        // 主窗口打开期间切到 .regular（同时出现 Dock 图标），关闭后切回常驻托盘形态。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        guard let window = controller.window else { return }
        // 最小化的窗口用 makeKeyAndOrderFront 唤不出来，必须先取消最小化。
        if window.isMiniaturized { window.deminiaturize(nil) }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // 摆到主屏。立即摆一次，再延到下一个 runloop 摆一次——SwiftUI 承载视图会在
        // 布局完成后调整窗口尺寸/位置，早于它做会被覆盖，多显示器下就表现为「窗口跑到外接屏/看不到」。
        placeOnScreen(window, homeScreen)
        DispatchQueue.main.async { [weak self] in
            self?.placeOnScreen(window, homeScreen)
        }
    }

    /// 窗口若没有完整落在指定屏幕的可见区域内，就居中到该屏。
    private func placeOnScreen(_ window: NSWindow, _ screen: NSScreen?) {
        guard let screen, !screen.visibleFrame.contains(window.frame) else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        window.setFrame(
            NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
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
        // 不做跨会话位置记忆：既不用 frameAutosaveName，也关掉 macOS 的窗口状态还原（Resume）。
        // 多显示器下它们会把窗口还原到另一台外接屏 / 已断开的屏幕，用户点了却看不到，
        // 表现为「打不开 / 没反应」。改为每次打开时居中到主屏（见 showMainWindow）。
        window.isRestorable = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: MainWindowView().environment(appState)
        )
        window.center()
        return NSWindowController(window: window)
    }
}
