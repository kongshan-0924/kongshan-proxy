import AppKit
import Foundation
import KongshanCore
import XCTest
@testable import kongshan

@MainActor
final class MenuBarViewStabilityTests: XCTestCase {
    func testStatusUpdatesKeepPanelControllerAndReleaseClosedTree() throws {
        let controller = makeController()
        defer { controller.stop() }
        let original = controller.panelController
        XCTAssertNil(original.mainContentView, "未打开时不构建 SwiftUI 树")
        controller.updateStatusButton(uploadText: "1.2M", downloadText: "3.4K")
        let firstImage = controller.statusItem.button?.image
        controller.updateStatusButton(uploadText: "1.2M", downloadText: "3.4K")
        XCTAssertTrue(controller.statusItem.button?.image === firstImage)
        weak var content: NSView?
        autoreleasepool {
            controller.toggleMenuPanel()
            content = original.mainContentView
            XCTAssertNotNil(content)
            controller.updateStatusButton(uploadText: "9.9K", downloadText: "8.8M")
            XCTAssertTrue(original.mainContentView === content)
            controller.toggleMenuPanel()
        }
        XCTAssertTrue(controller.panelController === original)
        XCTAssertNil(original.mainContentView)
        XCTAssertNil(content, "关闭必须释放 hosting 树，不只是隐藏窗口")
        XCTAssertNil(controller.statusItem.menu)
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

    func testCommandDUsesInjectedActionAndClosesMenuPanel() throws {
        var openCount = 0
        let controller = makeController { _ in openCount += 1 }
        defer { controller.stop() }
        controller.toggleMenuPanel()
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 0, windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: 2))
        XCTAssertTrue(controller.panelController.handleKey(event))
        XCTAssertEqual(openCount, 1)
        XCTAssertFalse(controller.panelController.isShown)
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

        // 托盘必须是 AppKit 的 NSStatusItem，不能是 SwiftUI 的 MenuBarExtra——
        // 周期性速度刷新会让后者重建正在跟踪的菜单。
        // 唯一允许的 MenuBarExtra 是**不插入**的场景占位（2026-09-18 为消除空白设置窗口引入，
        // 见 KongshanApp.body）：它不产生状态项，与托盘无关。按行检查，真托盘照样挡得住。
        let extraLines = appSource.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .filter { $0.contains("MenuBarExtra(") }
        XCTAssertTrue(
            extraLines.allSatisfy { $0.contains("isInserted: .constant(false)") },
            "MenuBarExtra 只允许作不插入的场景占位，托盘必须走 AppKit：\(extraLines)"
        )
        XCTAssertTrue(controllerSource.contains("NSStatusBar.system.statusItem"))
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

    /// 左右键共用状态项 action 与面板控制器：左键连点开合，右键打开后左键也能收起。
    func testLeftAndRightClickToggleSameMenuPanel() throws {
        let controller = makeController()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem.button)
        XCTAssertNotNil(button.action)
        XCTAssertTrue(button.target === controller)
        XCTAssertNil(controller.statusItem.menu)
        let panel = controller.panelController

        // 直接驱动左键入口，避免测试依赖真实状态栏鼠标事件分发。
        controller.statusItemClicked()
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(panel.loadedPanelCount, 1, "打开时只能有一个主面板实例")
        controller.statusItemClicked()
        XCTAssertFalse(panel.isShown)
        XCTAssertNil(panel.mainContentView)

        // 右键与左键汇入同一 toggle；右键打开后，左键入口必须能关闭。
        controller.toggleMenuPanel()
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(panel.loadedPanelCount, 1)
        controller.statusItemClicked()
        XCTAssertFalse(panel.isShown)
        XCTAssertEqual(panel.loadedPanelCount, 0)
    }

    /// 源码守卫：高频数值视图不得挂**按帧或按秒**的重绘驱动。`.smooth` 弹簧在下一次采样
    /// 到来时仍未收敛，SwiftUI 会按屏幕刷新率持续插值字形；这些文件里的数值全部每 1~2 秒变化。
    /// 低频动画（如 MainWindowView 的通知条）不受此限制。
    ///
    /// 判据从"禁止 TimelineView"收窄到"禁止它的高频档位"（2026-09-03）：
    /// 本意一直是挡住高频重绘，而 `TimelineView(.everyMinute)` 每分钟才走一次，
    /// 正是用来**替掉**每秒刷新的 `Text(_:style:.timer)` 的——按名字一刀切会把
    /// 降频的改动也挡在外面。`.animation` / `.periodic` 两档仍然禁止。
    func testHighFrequencyValueViewsCarryNoPerFrameRedrawDrivers() throws {
        let root = projectRoot()
        for file in [
            "Sources/kongshan/DashboardView.swift",
            "Sources/kongshan/MenuBarPanelView.swift",
            "Sources/kongshan/MenuBarPanelNodes.swift"
        ] {
            let source = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            XCTAssertFalse(source.contains(".animation("), "\(file) 不得使用 .animation(")
            XCTAssertFalse(source.contains(".contentTransition("), "\(file) 不得使用 .contentTransition(")
            XCTAssertFalse(source.contains("TimelineView(.animation"), "\(file) 不得按帧重绘")
            XCTAssertFalse(source.contains("TimelineView(.periodic"), "\(file) 不得用自定义周期，只允许 .everyMinute")
            XCTAssertFalse(source.contains("style: .timer"), "\(file) 不得用每秒自更新的计时文本")
        }
    }

    private func makeController(openMainWindow: @escaping (SidebarPage?) -> Void = { _ in }) -> MenuBarController {
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
