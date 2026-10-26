import Foundation
import XCTest

final class MainWindowToolbarTests: XCTestCase {
    /// 窗口只能有一个侧栏开关，且位置固定在工具栏最左。
    ///
    /// 2026-10-23 起主窗口改为自绘侧栏（`HStack` + 定宽侧栏），不再用 `NavigationSplitView`，
    /// 系统也就不会再塞第二个开关；这里钉死"自绘开关只有一处、由 `sidebarCollapsed` 驱动"。
    func testMainWindowUsesOneFixedSidebarToggle() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainWindowSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/MainWindowView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/KongshanApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(mainWindowSource.contains("@State private var sidebarCollapsed = false"))
        XCTAssertFalse(mainWindowSource.contains("NavigationSplitView("), "系统分栏会自带第二个侧栏开关")
        XCTAssertEqual(
            mainWindowSource.components(separatedBy: "ToolbarItem(placement: .navigation)").count - 1,
            1
        )
        XCTAssertFalse(mainWindowSource.contains("isSidebarCompact"))
        XCTAssertFalse(appSource.contains("removeSystemSidebarToggle"))
    }
}
