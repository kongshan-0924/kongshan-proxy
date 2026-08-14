import AppKit
import KongshanCore
import SwiftUI

@main
struct KongshanApp: App {
    @NSApplicationDelegateAdaptor(KongshanAppDelegate.self) private var appDelegate

    var body: some Scene {
        // 状态项由 AppKit 管理，避免周期性速度刷新让 SwiftUI 重建正在跟踪的菜单。
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class KongshanAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// 由 delegate 直接持有，避免依赖某个视图先出现才完成注入；
    /// 否则用户没打开过菜单时 applicationShouldTerminate 会拿不到状态，退出时不还原系统代理。
    let appState = AppState()

    private var mainWindowController: NSWindowController?
    private var menuBarController: MenuBarController?
    private var preparingToTerminate = false

    /// LSUIElement 应用启动时不会被激活（实测 `isActive=false`、`ppid=1`、
    /// `XPC_SERVICE_NAME` 与登录项同形），因此无法用激活状态或环境变量区分启动来源。
    /// 改用确定信号：开机自启已启用时，冷启动几乎必然来自 launchd 的登录项，保持菜单栏静默常驻；
    /// 其余情况都是用户主动打开，直接展示主窗口。
    /// 自启开启时若用户手动重开应用，再次双击图标会走 reopen 打开窗口。
    /// 已在运行的同 bundle ID 实例（不含自己）。抽成属性只为让下面的意图一眼可读。
    private var otherRunningInstances: [NSRunningApplication] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != selfPID }
    }

    /// 单实例保护。**必须在做任何事之前**。
    ///
    /// 两个实例同时跑对这个应用是有害的，不只是程序坞里多个图标：两边都会去改
    /// 系统代理与系统 DNS，各自持有一份「原始设置」快照。后退出的那个会拿着**已经被
    /// 对方改过**的快照去"还原"，把代理设置永久写成指向一个已经关掉的端口。
    ///
    /// 真机遇到过：`/Applications` 与工作区 `dist/` 两个副本同时在跑
    /// （构建产物被 Launch Services 记着，任何一次误启动就会拉起第二个）。
    func applicationWillFinishLaunching(_ notification: Notification) {
        // M4 launches a second, fully isolated no-node candidate while the
        // installed app keeps the user's network online. Only the tightly
        // scoped verifier directory may bypass single-instance protection.
        if AppIdentity.releaseVerificationSupportDirectory() != nil { return }
        guard let existing = otherRunningInstances.first else { return }
        existing.activate(options: [.activateAllWindows])
        // 用 exit 而不是 NSApp.terminate：terminate 会走 applicationShouldTerminate，
        // 那里有还原系统代理的逻辑。本实例什么都没接管过，不该参与还原。
        exit(EXIT_SUCCESS)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGPIPE 默认会**直接杀掉进程**。App 会往内核 stdin 的管道里写几百 KB 配置
        // （SingBoxProcess.start / PrivilegedHelperClient.start）；内核若在读完前就退出
        // （端口被占、配置被拒），写端拿到 EPIPE 的同时收到 SIGPIPE → 整个 App 被杀。
        // 全局忽略一次，write 改为返回 -1/EPIPE 由各写入点自行处理。
        signal(SIGPIPE, SIG_IGN)
        let menuBarController = MenuBarController(
            state: appState,
            openMainWindow: { [weak self] in self?.showMainWindow() }
        )
        self.menuBarController = menuBarController
        menuBarController.start()
        // 会话累计流量必须跨窗口关闭持续采样，因此保留常驻监控消费者；状态项本身
        // 的整机速度由 MenuBarController 独立采样，不进入 SwiftUI Observation 图。
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

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
    }

    private func makeMainWindowController() -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "kongshan"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 820, height: 540)
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
