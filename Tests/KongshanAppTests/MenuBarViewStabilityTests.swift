import Foundation
import XCTest

final class MenuBarViewStabilityTests: XCTestCase {
    func testMenuBarExtraDoesNotObserveLiveRates() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/MenuBarView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/KongshanApp.swift"),
            encoding: .utf8
        )

        let menuBarSource = menuSource + appSource
        XCTAssertFalse(menuBarSource.contains("state.uploadRate"))
        XCTAssertFalse(menuBarSource.contains("state.downloadRate"))
        XCTAssertFalse(menuBarSource.contains("state.nicUploadText"))
        XCTAssertFalse(menuBarSource.contains("state.nicDownloadText"))
    }

    func testOpenPanelUsesInjectedAction() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let menuSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/MenuBarView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: projectRoot.appending(path: "Sources/kongshan/KongshanApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(menuSource.contains("let openMainWindow: () -> Void"))
        XCTAssertFalse(menuSource.contains("NSApp.delegate"))
        XCTAssertTrue(appSource.contains("MenuBarView(openMainWindow: appDelegate.showMainWindow)"))
    }
}
