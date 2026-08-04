import AppKit
import Foundation
import XCTest
@testable import kongshan

@MainActor
final class MenuBarViewStabilityTests: XCTestCase {
    func testStatusUpdatesKeepPersistentMenuInstance() {
        let controller = makeController()
        defer { controller.stop() }
        let originalMenu = controller.menu

        controller.updateStatusButton(uploadText: "1.2M", downloadText: "3.4K")
        let firstImage = controller.statusItem.button?.image
        controller.updateStatusButton(uploadText: "1.2M", downloadText: "3.4K")
        XCTAssertTrue(controller.statusItem.button?.image === firstImage)
        controller.menuWillOpen(controller.menu)
        controller.updateStatusButton(uploadText: "9.9K", downloadText: "8.8M")

        XCTAssertTrue(controller.menu === originalMenu)
        XCTAssertTrue(controller.statusItem.menu === originalMenu)
        XCTAssertFalse(controller.menu.autoenablesItems)
        XCTAssertFalse(controller.menu.items.isEmpty)
    }

    func testStatusImageWidthDoesNotDependOnRateText() {
        let narrow = MenuBarIcon.statusImage(style: .peak, state: .off, uploadText: "—", downloadText: "—")
        let wide = MenuBarIcon.statusImage(
            style: .peak,
            state: .off,
            uploadText: "999.9M",
            downloadText: "999.9M"
        )

        XCTAssertEqual(narrow.size, wide.size)
        XCTAssertLessThanOrEqual(
            MenuBarIcon.statusTextRenderedWidth(MenuBarIcon.widestRateSample),
            MenuBarIcon.statusTextWidth
        )
    }

    func testOpenPanelUsesInjectedNativeAction() throws {
        var openCount = 0
        let controller = makeController { openCount += 1 }
        defer { controller.stop() }
        controller.rebuildMenu()

        let item = try XCTUnwrap(controller.menu.items.first { $0.title == "打开仪表盘" })
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: item.target, from: item))
        XCTAssertEqual(openCount, 1)
    }

    func testTrayUsesAppKitAndKeepsLiveRatesOutOfSwiftUI() throws {
        let root = projectRoot()
        let appSource = try String(
            contentsOf: root.appending(path: "Sources/kongshan/KongshanApp.swift"),
            encoding: .utf8
        )
        let controllerSource = try String(
            contentsOf: root.appending(path: "Sources/kongshan/MenuBarController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(appSource.contains("MenuBarExtra"))
        XCTAssertTrue(controllerSource.contains("NSStatusBar.system.statusItem"))
        XCTAssertTrue(controllerSource.contains("let menu = NSMenu()"))
        XCTAssertTrue(controllerSource.contains("NetworkThroughput.physicalCounters()"))
        XCTAssertFalse(controllerSource.contains("state.uploadRate"))
        XCTAssertFalse(controllerSource.contains("state.downloadRate"))
    }

    func testMenuRateFormatterIsCompact() {
        XCTAssertEqual(MenuRateFormatter.displayText(0), "—")
        XCTAssertEqual(MenuRateFormatter.compact(900), "900B")
        XCTAssertEqual(MenuRateFormatter.compact(1_536), "1.5K")
        XCTAssertEqual(MenuRateFormatter.compact(5 * 1_048_576), "5.0M")
        XCTAssertEqual(MenuRateFormatter.compact(2 * 1_073_741_824), "2.0G")
    }

    private func makeController(openMainWindow: @escaping () -> Void = {}) -> MenuBarController {
        let state = AppState(automaticallyInitialize: false)
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        return MenuBarController(state: state, statusItem: statusItem, openMainWindow: openMainWindow)
    }

    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
