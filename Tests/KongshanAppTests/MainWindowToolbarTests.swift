import Foundation
import XCTest

final class MainWindowToolbarTests: XCTestCase {
    func testMainWindowUsesOnlyNativeSidebarToggle() throws {
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

        XCTAssertFalse(mainWindowSource.contains("isSidebarCompact"))
        XCTAssertFalse(mainWindowSource.contains("ToolbarItem(placement: .navigation)"))
        XCTAssertFalse(mainWindowSource.contains(".toolbar(removing: .sidebarToggle)"))
        XCTAssertFalse(appSource.contains("removeSystemSidebarToggle"))
    }
}
