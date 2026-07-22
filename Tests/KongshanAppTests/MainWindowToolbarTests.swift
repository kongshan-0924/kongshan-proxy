import Foundation
import XCTest

final class MainWindowToolbarTests: XCTestCase {
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

        XCTAssertTrue(mainWindowSource.contains("@State private var columnVisibility: NavigationSplitViewVisibility = .all"))
        XCTAssertTrue(mainWindowSource.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
        XCTAssertTrue(mainWindowSource.contains(".toolbar(removing: .sidebarToggle)"))
        XCTAssertEqual(
            mainWindowSource.components(separatedBy: "ToolbarItem(placement: .navigation)").count - 1,
            1
        )
        XCTAssertFalse(mainWindowSource.contains("isSidebarCompact"))
        XCTAssertFalse(appSource.contains("removeSystemSidebarToggle"))
    }
}
