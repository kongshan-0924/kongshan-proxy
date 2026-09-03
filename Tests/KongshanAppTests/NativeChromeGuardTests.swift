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
}
