import AppKit
import KongshanCore
import SwiftUI

@main
struct KongshanApp: App {
    @NSApplicationDelegateAdaptor(KongshanAppDelegate.self) private var appDelegate

    var body: some Scene {
        // `App` 要求至少一个 Scene，但主窗口与状态项都由 AppKit 自己管（见 delegate；
        // 状态项不用 SwiftUI，是为了避免周期性速度刷新让它重建正在跟踪的菜单）。
        //
        // **这里原本是 `Settings { EmptyView() }`，它是个窗口场景，会被三条路径开出空白窗口**
        // （用户 2026-09-18 截图：标题 "kongshan Settings" 的空窗，还抢走主窗口焦点，
        // 主窗口随即按失焦样式渲染，整个界面看上去一片灰）：
        //   1. ⌘, / App 菜单「设置…」——Settings 场景自带的菜单项；
        //   2. 点 Dock 图标重开——reopen 返回 true 时 SwiftUI 会为第一个场景开窗口；
        //   3. 启动本身——装好 0.2.3 后真机取证，什么都没按，窗口列表里就只有它（is_main）。
        // 逐条去堵要用 `defaultLaunchBehavior(.suppressed)`，那是 macOS 15 的 API，
        // 而部署目标是 14、`SceneBuilder` 又不支持 `if #available`。
        //
        // 换成**不插入**的 `MenuBarExtra`：它满足 Scene 要求，却既不产生窗口、也不插状态项——
        // 没有窗口场景，三条路径也就都无从开出空窗。⌘, 仍改道到应用自己的设置页。
        MenuBarExtra("kongshan", isInserted: .constant(false)) {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    appDelegate.showSettingsPage()
                }
                .keyboardShortcut(",", modifiers: .command)
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
    ///
    /// **必须返回 `false`**。返回 `true` 的语义是「我处理完了，请你再执行默认的重开动作」，
    /// 而 SwiftUI App 的默认重开动作是**为第一个场景开一个窗口**——这里唯一的场景就是那个
    /// 为凑数而存在的空 `Settings`。于是每次点 Dock 图标都会冒出一个 "kongshan Settings" 空窗，
    /// 和主窗口并排（正是用户 2026-09-18 截图里两个窗口同时出现的样子），还会抢走焦点。
    /// 主窗口已由 `showMainWindow()` 亲自处理，不需要任何默认动作。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// 打开主窗口并切到设置页。⌘, 与 App 菜单「设置…」走这里，见 `KongshanApp.body`。
    func showSettingsPage() {
        showMainWindow()
        appState.requestPage(.settings)
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
        // 内容区底色：详情面板由 SwiftUI 透明承载，实际透出的是窗口底色。
        // 默认的 windowBackgroundColor 与 GroupBox 同为浅灰，卡片立不起来。见 Theme 的说明。
        window.backgroundColor = Theme.windowBackgroundColor
        // 真标题栏 + 统一工具栏：页面标题/副标题与操作都进工具栏，不再各页自绘页头。
        // 副标题承载统计（邮件写"收件箱 — 12 封"，这里写"连接 — 12 条 · ↑ 1.2 MB/s"）。
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        // 各页布局已做自适应（仪表盘自适应网格、代理页弹性列、日志工具条折行），
        // 最小尺寸可以再放小一档，小屏/分屏也能用。
        window.minSize = NSSize(width: 760, height: 500)
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
