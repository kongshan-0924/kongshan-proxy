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
        "Theme.swift", "MainWindowView.swift", "DashboardView.swift", "PolicyGroupsView.swift",
        "RoutingView.swift", "ConnectionsView.swift", "LogsView.swift", "MessagesView.swift",
        "MenuBarPopoverView.swift"
    ]

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
        for file in ["DashboardView.swift", "ConnectionsView.swift", "LogsView.swift",
                     "MessagesView.swift", "PolicyGroupsView.swift", "RoutingView.swift"] {
            XCTAssertTrue(try source(file).contains(".navigationSubtitle("), "\(file) 应把统计放进副标题")
        }
        // 配置页与设置页在 MainWindowView 里。
        XCTAssertEqual(try source("MainWindowView.swift").components(separatedBy: ".navigationSubtitle(").count - 1, 2)
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

    /// 指标网格是**六张卡、列数只取 6 的因数**。用 `.adaptive` 会在某些宽度下排成
    /// 4 或 5 列，最后一行缺两个角——用户 2026-09-03 反馈的「首页有两个空的」。
    func testDashboardMetricsGridNeverLeavesAGaggedRow() throws {
        let dashboard = try source("DashboardView.swift")
        XCTAssertFalse(dashboard.contains("GridItem(.adaptive"), "自适应列会排出缺角的最后一行")
        XCTAssertTrue(dashboard.contains("count: metricColumns"))
        // 会随流量变化的四张卡各自是独立视图（Observation 只失效自己），见 DashboardObservationScopeTests。
        for box in ["ExitIPMetricBox", "ConnectionsMetricBox", "CoreMemoryMetricBox", "runtimeBox", "activeConfigBox", "SelfUsageMetricBox"] {
            XCTAssertTrue(dashboard.contains(box), "缺少指标卡 \(box)")
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
