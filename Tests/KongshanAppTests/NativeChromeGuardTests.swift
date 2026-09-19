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
        "DashboardView.swift", "PolicyGroupsView.swift", "RoutingView.swift", "ConnectionsView.swift",
        "LogsView.swift", "MessagesView.swift", "MenuBarPopoverView.swift"
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

    /// 内容区底色不得回到默认的 `windowBackgroundColor`：浅色模式下它与 `GroupBox` 同为浅灰，
    /// 灰底摆灰卡、没有层次（用户 2026-09-18「整体页面太灰了」）。
    func testMainWindowUsesContentBackgroundColor() throws {
        let app = try source("KongshanApp.swift")
        XCTAssertTrue(app.contains("window.backgroundColor = Theme.windowBackgroundColor"))
        XCTAssertTrue(try source("Theme.swift").contains("NSColor.controlBackgroundColor"))
    }

    /// 系统容器（GroupBox / Form / List / Table）自带层次，不需要也不该再叠投影。
    func testNoDropShadowsAnywhereInViews() throws {
        for file in viewFiles {
            XCTAssertFalse(try source(file).contains(".shadow("), "\(file) 不该有投影")
        }
    }

    /// 页头由真标题栏承担：标题 `.navigationTitle`、统计 `.navigationSubtitle`、操作进 `.toolbar`。
    func testPagesUseNativeTitleBarInsteadOfHandDrawnHeaders() throws {
        for file in viewFiles {
            XCTAssertFalse(try source(file).contains("PageHeader("), "\(file) 不该再自绘页头")
        }
        // 配置页与设置页原先与主窗口同文件，2026-09-17 拆成 NodesView / SettingsView 各自一份。
        for file in ["DashboardView.swift", "ConnectionsView.swift", "LogsView.swift",
                     "MessagesView.swift", "PolicyGroupsView.swift", "RoutingView.swift",
                     "NodesView.swift", "SettingsView.swift"] {
            XCTAssertTrue(try source(file).contains(".navigationSubtitle("), "\(file) 应把统计放进副标题")
        }
        let app = try source("KongshanApp.swift")
        XCTAssertTrue(app.contains("window.titleVisibility = .visible"), "标题栏必须可见")
        XCTAssertTrue(app.contains("window.toolbarStyle = .unified"), "统一工具栏")
    }

    /// 搜索用系统 `.searchable`，会进工具栏并自带快捷键；自绘搜索框没有这些。
    func testSearchUsesSystemSearchable() throws {
        XCTAssertFalse(try source("Theme.swift").contains("struct SearchField"))
        for file in ["ConnectionsView.swift", "LogsView.swift", "PolicyGroupsView.swift", "RoutingView.swift"] {
            XCTAssertTrue(try source(file).contains(".searchable("), "\(file) 应使用 .searchable")
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

    /// 指标网格：**列数候选必须整除卡片数**，否则最后一行缺角——
    /// 用户 2026-09-03 反馈的「首页有两个空的」就是 `.adaptive` 排出 4/5 列造成的。
    ///
    /// 这里不再硬编码卡片名单，而是直接从源码数出网格里的卡片数，再验证每个列数候选都能整除它。
    /// 加卡、减卡时这条会自动跟着变——名单式断言只会在改动时报"缺少某某卡"，帮不上判断。
    func testDashboardMetricsGridNeverLeavesAGaggedRow() throws {
        let dashboard = try source("DashboardView.swift")
        XCTAssertFalse(dashboard.contains("GridItem(.adaptive"), "自适应列会排出缺角的最后一行")
        XCTAssertTrue(dashboard.contains("count: metricColumns"))

        // 网格体：LazyVGrid 的尾随闭包到 `.background {` 之间。
        let gridStart = try XCTUnwrap(dashboard.range(of: "count: metricColumns"))
        let gridEnd = try XCTUnwrap(dashboard.range(of: ".background {", range: gridStart.upperBound..<dashboard.endIndex))
        let body = dashboard[gridStart.upperBound..<gridEnd.lowerBound]
        let cardCount = body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty, !line.hasPrefix("//"), !line.hasPrefix(")"), !line.hasPrefix("]") else { return false }
                return line.hasSuffix("()") || line.hasSuffix("Box")
            }
            .count
        XCTAssertGreaterThan(cardCount, 0, "没数出任何指标卡，断言本身失效了")

        let candidates = try XCTUnwrap(
            dashboard.range(of: "let candidates: [Int] = [").map { range -> [Int] in
                let tail = dashboard[range.upperBound...]
                let inside = tail.prefix { $0 != "]" }
                return inside.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
        )
        XCTAssertFalse(candidates.isEmpty, "没解析出列数候选")
        for candidate in candidates {
            XCTAssertEqual(
                cardCount % candidate, 0,
                "\(cardCount) 张卡排 \(candidate) 列会缺角；候选列数必须整除卡片数"
            )
        }
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
        XCTAssertTrue(policy.contains(".listStyle(.inset)"))
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
