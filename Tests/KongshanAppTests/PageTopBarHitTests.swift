import AppKit
import KongshanCore
import SwiftUI
import XCTest
@testable import kongshan

/// 页内顶栏在真实主窗口（fullSizeContentView + 统一工具栏）里必须能点到。
///
/// 2026-11-09 离屏命中测试发现：顶栏与页面滚动视图之间没有间隙时，macOS 26 把仪表盘、设置、诊断等
/// 滚动页的 ScrollView 伸进工具栏高度带，盖一层滚动边缘效果视图（BackdropView），顶栏按钮与拖动全被截走。
/// 修法是 `Theme.topBarGap`；这里钉住「顶栏高度带里的命中不落在任何滚动视图里」。
@MainActor
final class PageTopBarHitTests: XCTestCase {
    func testTopBarIsNotCoveredByPageScrollView() throws {
        for page in SidebarPage.allCases {
            let state = AppState(
                storage: Storage(rootDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "kongshan-hit-\(UUID().uuidString)")),
                automaticallyInitialize: false
            )
            state.isReady = true
            state.lastMainWindowPage = page
            let content = MainWindowContentHost(state: state)
            let window = HitTestWindow(
                contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentView = content.hostingView
            window.setFrame(NSRect(x: -10_000, y: -10_000, width: 960, height: 640), display: false)
            window.orderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            content.hostingView.layoutSubtreeIfNeeded()

            let frameView = try XCTUnwrap(content.hostingView.superview)
            // 顶栏空白处（详情列中部、红绿灯那一行）。
            let point = NSPoint(x: 560, y: frameView.bounds.height - Theme.topBarHeight / 2)
            var view = frameView.hitTest(point)
            var insideScrollView = false
            while let current = view {
                if current is NSScrollView { insideScrollView = true }
                view = current.superview
            }
            XCTAssertFalse(insideScrollView, "\(page.rawValue)：顶栏被页面滚动视图盖住，按钮与拖动会失效")
            window.orderOut(nil)
            content.detach()
        }
    }
}

/// 离屏窗口：ssh 下没有屏幕时系统会把外框约束成怪尺寸，这里原样保留。
private final class HitTestWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
