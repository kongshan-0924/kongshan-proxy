import Foundation
import XCTest

/// 原生 macOS 界面的源码守卫。
///
/// 设计决策写在 `docs/design/NATIVE_UI.md`；这里把最容易悄悄退化的几条钉死：
/// 投影、自绘页头、自绘搜索框回来一个，界面就又开始像 web 仪表盘。
/// 源码守卫而不是截图比对：截图会被系统版本、字体渲染、深浅色搅乱，
/// 而"有没有 `.shadow(`"这种事实不会。
final class NativeChromeGuardTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/\(name)"),
            encoding: .utf8
        )
    }

    private let viewFiles = [
        "Theme.swift", "MainWindowView.swift", "NodesView.swift", "SettingsView.swift", "ManualNodeSheet.swift",
        "DashboardView.swift", "DashboardRoute.swift", "RouteHeaderView.swift", "PolicyGroupsView.swift", "RoutingView.swift", "ConnectionsView.swift",
        "LogsView.swift", "MessagesView.swift"
    ]

    /// ⌘, 与 App 菜单「设置…」不得打开空白的 `Settings` 场景。
    ///
    /// 2026-09-18 用户截图：标题 "kongshan Settings" 的空窗。那个场景只为满足
    /// `App` 至少一个 Scene 而存在，却顺带挂上了设置菜单项；更糟的是空窗会抢走主窗口焦点，
    /// 主窗口随即按失焦样式渲染（侧栏选中项变灰、材质压平），用户的直观感受就是「整体太灰」。
    func testSettingsShortcutRoutesToInAppSettingsPage() throws {
        let app = try source("KongshanApp.swift")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .appSettings)"), "⌘, 必须改道，不能落到空场景")
        XCTAssertTrue(app.contains("showSettingsPage()"), "改道目标应是应用自己的设置页")
        // 窗口场景会被启动、Dock 重开、⌘, 三条路径各自开出空窗；占位必须是不产生窗口的场景。
        // 只看代码行：注释里为说明来龙去脉会提到原来的 `Settings { EmptyView() }`。
        let code = app.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertFalse(code.contains("Settings {"), "不得用 Settings 场景占位——它会开出空白窗口")
        XCTAssertFalse(code.contains("WindowGroup {"), "主窗口由 AppKit 管，不得再有 SwiftUI 窗口场景")
        XCTAssertTrue(app.contains("isInserted: .constant(false)"), "占位的 MenuBarExtra 必须不插入，否则会多出一个状态项")
        // reopen 返回 true 会让 SwiftUI 再为第一个场景开窗口。
        XCTAssertTrue(app.contains("showMainWindow()\n        return false"), "reopen 已亲自开了主窗口，必须返回 false")
        let window = try source("MainWindowView.swift")
        XCTAssertTrue(
            window.contains(".onChange(of: state.requestedPage, initial: true)"),
            "首次打开窗口时跳转请求先于第一次求值写入，没有 initial 就会停在仪表盘"
        )
    }

    /// 内容区底色不得回到默认的 `windowBackgroundColor`（灰）：浅色模式下它与 `GroupBox` 同为浅灰，
    /// 灰底摆灰卡、没有层次。2026-10-23 起画布改用自定义极浅冷灰动态色（卡片纯白浮其上），
    /// 这里钉死"画布是自定义动态色、不是系统默认灰"。
    func testMainWindowUsesContentBackgroundColor() throws {
        let app = try source("KongshanApp.swift")
        XCTAssertTrue(app.contains("window.backgroundColor = Theme.windowBackgroundColor"))
        let theme = try source("Theme.swift")
        XCTAssertTrue(theme.contains("static let windowBackgroundColor = NSColor(name: nil)"), "画布应为自定义动态色")
        XCTAssertTrue(theme.contains("static let canvasBackground = Color(nsColor: windowBackgroundColor)"), "画布应跟随窗口底色")
    }

    /// 系统容器（GroupBox / Form / List / Table）自带层次，不需要也不该再叠投影。
    func testNoDropShadowsAnywhereInViews() throws {
        for file in viewFiles {
            XCTAssertFalse(try source(file).contains(".shadow("), "\(file) 不该有投影")
        }
    }

    /// 页面按钮在页内顶栏（PageTopBar），窗口工具栏只留固定的侧栏开关。
    /// 各页各自声明 `.toolbar` / `.searchable` / `.navigationSubtitle` 时，每次切页 AppKit 都要拆掉重建整条工具栏，
    /// 占切页耗时约三成（2026-11-09 iMac 采样，用户选方案 A）。
    func testPagesUsePageTopBarInsteadOfWindowToolbar() throws {
        for file in viewFiles {
            let code = try source(file)
            XCTAssertFalse(code.contains("PageHeader("), "\(file) 不该再自绘页头")
            guard file != "MainWindowView.swift" else { continue }
            XCTAssertFalse(code.contains(".toolbar {"), "\(file) 的按钮应放进 .pageTopBar")
            XCTAssertFalse(code.contains(".searchable("), "\(file) 的搜索应用 TopBarSearchField")
            XCTAssertFalse(code.contains(".navigationSubtitle("), "\(file)：标题栏隐藏，副标题看不见还会触发标题栏重排")
        }
        // 主窗口里的每一页都必须挂页内顶栏：详情列忽略顶部安全区，不挂的页面会顶进红绿灯那一行。
        for file in ["DashboardView.swift", "NodesView.swift", "PolicyGroupsView.swift", "RoutingView.swift",
                     "ConnectionsView.swift", "LogsView.swift", "DiagnosticsView.swift", "SettingsView.swift"] {
            XCTAssertTrue(try source(file).contains(".pageTopBar"), "\(file) 应挂 .pageTopBar")
        }
        let main = try source("MainWindowView.swift")
        XCTAssertTrue(main.contains(".ignoresSafeArea(.container, edges: .top)"))
        XCTAssertEqual(main.components(separatedBy: "ToolbarItem(").count - 1, 1, "窗口工具栏只能有固定的侧栏开关")
        let app = try source("KongshanApp.swift")
        XCTAssertTrue(app.contains(".fullSizeContentView"), "详情列要伸进标题栏高度带")
        XCTAssertTrue(app.contains("window.titleVisibility = .hidden"), "极简顶栏标题应隐藏")
        XCTAssertTrue(app.contains("window.titlebarSeparatorStyle = .none"), "极简顶栏应去掉分割线")
        XCTAssertTrue(app.contains("window.toolbarStyle = .unified"), "统一工具栏（高度带与页内顶栏等高）")
    }

    /// 主窗口隐藏了标题栏，`.navigationSubtitle` 不再显示；页面里看不到的常驻统计
    /// （连接数与总速率、日志行数、共享监听状态）必须挪进底部状态条，不能跟着标题栏一起消失。
    func testHiddenTitleBarStatsLiveInPageStatusBar() throws {
        XCTAssertTrue(try source("KongshanApp.swift").contains("window.titleVisibility = .hidden"))
        for file in ["ConnectionsView.swift", "LogsView.swift", "SharingView.swift"] {
            XCTAssertTrue(try source(file).contains("PageStatusBar("), "\(file) 的统计应放进底部状态条")
        }
    }

    /// 控件统一（2026-10-24）：分段选择用 `CapsuleSegmentedPicker`、表单用 `CardForm`/`CardSection`、
    /// 按钮用 `.pill`/`.pillProminent`、输入框用 `.inputField()`。系统件混进来一个，界面就又是两套。
    /// 默认 `Capsule()` 在当前 SDK 下描边两侧会冒出竖线，必须写 `Capsule(style: .circular)`。
    func testControlsUseUnifiedComponents() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: projectRoot().appending(path: "Sources/kongshan").path)
            .filter { $0.hasSuffix(".swift") }
        for file in files {
            let code = try source(file).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains(".pickerStyle(.segmented)"), "\(file) 应改用 CapsuleSegmentedPicker")
            XCTAssertFalse(code.contains(".borderedProminent"), "\(file) 应改用 .pillProminent")
            XCTAssertFalse(code.contains(".buttonStyle(.bordered)"), "\(file) 应改用 .pill")
            XCTAssertFalse(code.contains(".textFieldStyle(.roundedBorder)"), "\(file) 应改用 .inputField()")
            XCTAssertFalse(code.contains("Capsule()"), "\(file) 应写 Capsule(style: .circular)")
            XCTAssertNil(code.range(of: #"(?<![A-Za-z])Form \{"#, options: .regularExpression), "\(file) 应改用 CardForm")
        }
    }

    /// 搜索统一用页内顶栏的 `TopBarSearchField`（⌘F 聚焦、Esc 清空），不再用会进窗口工具栏的 `.searchable`。
    func testSearchUsesTopBarSearchField() throws {
        let theme = try source("Theme.swift")
        XCTAssertTrue(theme.contains(".keyboardShortcut(\"f\", modifiers: .command)"), "搜索框要保留 ⌘F")
        XCTAssertTrue(theme.contains(".onExitCommand"), "搜索框要保留 Esc 清空")
        for file in ["ConnectionsView.swift", "LogsView.swift", "PolicyGroupsView.swift", "RoutingView.swift"] {
            XCTAssertTrue(try source(file).contains("TopBarSearchField("), "\(file) 应使用 TopBarSearchField")
        }
    }

    /// 实时表格用 `Table`（活动监视器那种），不再自绘行。
    func testConnectionsUseNativeTable() throws {
        let connections = try source("ConnectionsView.swift")
        XCTAssertTrue(connections.contains("Table("))
        XCTAssertTrue(connections.contains("sortOrder"), "列必须可排序")
        // 匹配调用而不是单词：注释里提到 LazyVStack 是为了说明为什么不用它。
        XCTAssertFalse(connections.contains("LazyVStack("))
    }

    /// 渐变图标块是 web 仪表盘的装饰，系统件里没有这种东西。
    func testNoGradientIconTiles() throws {
        for file in viewFiles {
            XCTAssertFalse(try source(file).contains("IconBadge("), "\(file) 不该用渐变图标块")
        }
    }

    /// 高频数值不做动画——v0.1.79 那次 8 小时燃烧的教训，重构不能把它带回来。
    func testHighFrequencyNumbersStayUnanimated() throws {
        let dashboard = try source("DashboardView.swift")
        XCTAssertFalse(dashboard.contains(".contentTransition(.numericText"))
        XCTAssertFalse(dashboard.contains(".animation(.smooth"))
        XCTAssertTrue(dashboard.contains("transaction.animation = nil"), "图表必须关动画")
    }

    /// 仪表盘只有一套布局（2026-11-09 用户决定）：开不开代理，卡片数量、位置、尺寸、标题都不变，
    /// 未接管用卡内空状态（数值「—」+ 占位文案），不再切换到「配置详情 / 最近活动」。
    func testDashboardKeepsOneLayoutRegardlessOfTakeover() throws {
        let dashboard = try source("DashboardView.swift")
        XCTAssertTrue(dashboard.contains("RouteHeaderView(isCompact:"))
        XCTAssertTrue(dashboard.contains("DashboardTrafficGroup()"))
        XCTAssertFalse(dashboard.contains("DashboardIdleContent"), "未接管不再切换第二套布局")
        XCTAssertFalse(dashboard.contains("if hasTakeover"), "中部两卡不得再按接管状态显隐")
        XCTAssertFalse(dashboard.contains("GridItem(.adaptive"), "双卡仍用显式比例，不用自适应缺角网格")
        XCTAssertTrue(dashboard.contains("DashboardLayout.trafficShare"), "双卡宽度应按比例规范分配")
    }

    func testRouteModelDoesNotObserveHighFrequencyTraffic() throws {
        let route = try source("DashboardRoute.swift")
        for forbidden in ["trafficHistory", "trafficMinutes", "uploadRate", "downloadRate", "activeConnectionCount"] {
            XCTAssertFalse(route.contains(forbidden), "链路模型不能在整页作用域读取高频状态：\(forbidden)")
        }
    }

    func testMenuBarCollapsesSecondaryPolicyGroups() throws {
        let panel = try source("MenuBarPanelView.swift")
        XCTAssertTrue(panel.contains("groups.prefix(3)"), "主面板只直接展示前 3 个策略组")
        XCTAssertTrue(panel.contains("groups.count > 3"))
        XCTAssertTrue(panel.contains("title: \"更多策略组\""), "其余策略组必须收进更多策略组子面板")
    }

    func testSettingsCopyMatchesCurrentTUNBehavior() throws {
        let settings = try source("SettingsView.swift")
        XCTAssertFalse(settings.contains("当前版本不自动恢复 TUN"))
        XCTAssertFalse(settings.contains("默认不启用 fake-ip"))
        XCTAssertTrue(settings.contains("TUN 默认使用 Fake-IP"))
    }

    /// 运行时长不能用每秒自更新的 `.timer`：它嵌在指标网格里，每次刷新都要把整个
    /// GroupBox 网格重新布局。真机采样显示主线程持续耗在 layout 与视图图更新上。
    func testRuntimeDurationRefreshesPerMinuteNotPerSecond() throws {
        let dashboard = try source("DashboardView.swift")
        XCTAssertFalse(dashboard.contains("style: .timer"), "每秒刷新会把整个网格重新布局")
        XCTAssertTrue(dashboard.contains("TimelineView(.everyMinute)"))
        // minimumScaleFactor 在布局时要二分搜索字号，不能加在每秒变化的数值上。
        // 匹配调用而不是单词：注释里写了为什么不用它。
        XCTAssertFalse(dashboard.contains(".minimumScaleFactor("))
    }

    /// 代理页左列不能用 `.sidebar`：它会画侧栏材质，嵌在 detail 里就是一块灰底，
    /// 与右侧白色列表撞色（用户 2026-09-03 反馈）。
    func testPolicyGroupColumnDoesNotPaintSidebarMaterial() throws {
        let policy = try source("PolicyGroupsView.swift")
        XCTAssertFalse(policy.contains(".listStyle(.sidebar)"), "detail 里的第二层列表不该用侧栏材质")
        XCTAssertTrue(policy.contains("HuggingScrollStack("), "成员与策略组列表走懒加载贴合滚动")
    }

    /// 卡内长列表不能用 `ViewThatFits(in: .vertical)` 做「少时贴合、多时滚动」：它会把不滚动那份整列表
    /// 非懒加载地建好量一遍，300 个成员时切到代理页 1 s、日志页 350 ms（2026-11-09 iMac 基准）。
    func testCardListsDoNotMeasureWholeListWithViewThatFits() throws {
        for file in ["PolicyGroupsView.swift", "NodesView.swift", "MessagesView.swift"] {
            XCTAssertFalse(try source(file).contains("ViewThatFits(in: .vertical)"), file)
        }
    }

    /// 连接表默认列必须能在最小窗口（760pt）里放下，不然只能横向翻。
    /// 两个「累计」列默认隐藏，需要时右键表头勾出来。
    func testConnectionTableFitsMinimumWindowByDefault() throws {
        let connections = try source("ConnectionsView.swift")
        XCTAssertTrue(connections.contains("columnCustomization:"), "列应可自定义")
        XCTAssertEqual(
            connections.components(separatedBy: ".defaultVisibility(.hidden)").count - 1, 2,
            "两个累计列默认隐藏"
        )
        // 默认可见列的 ideal 宽合计：目标 220 + 规则 180 + 速率 76×2 + 关闭 28 = 580，
        // 最小窗口 760 减去侧栏 200 后仍有 560——留 20 余量给分隔线与内边距。
        XCTAssertTrue(connections.contains(".width(min: 140, ideal: 220)"))
        XCTAssertTrue(connections.contains(".width(min: 110, ideal: 180)"))
        XCTAssertTrue(connections.contains(".disabledCustomizationBehavior(.visibility)"), "主列不许隐藏")
    }
}
