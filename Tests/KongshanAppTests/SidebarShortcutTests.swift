import Foundation
import XCTest
@testable import kongshan

/// 侧栏 ⌘N 快捷键。
///
/// 第 10 页起**不能**再绑：`Character("10")` 不是单字符，`Character(_:)` 会直接 trap，
/// 而这段代码在主窗口构建路径上——加一页就是启动即崩。加「出口分析」时正好踩到第 10 页。
@MainActor
final class SidebarShortcutTests: XCTestCase {
    func testOnlyTheFirstNinePagesGetACommandShortcut() {
        for index in 0..<9 {
            XCTAssertNotNil(SidebarPage.shortcutKey(at: index), "第 \(index + 1) 页应有 ⌘\(index + 1)")
        }
        for index in [9, 10, 25] {
            XCTAssertNil(
                SidebarPage.shortcutKey(at: index),
                "第 \(index + 1) 页不能绑快捷键——Character(\"\(index + 1)\") 会 trap"
            )
        }
        XCTAssertNil(SidebarPage.shortcutKey(at: -1), "负索引同样不能构造")
    }

    /// 页数已经到 10：这条是在提醒——再加页时快捷键只覆盖前 9 个，别以为新页有 ⌘N。
    func testPageCountIsKnownAndExitAnalysisIsPresent() {
        XCTAssertEqual(SidebarPage.allCases.count, 10)
        let titles: [String] = SidebarPage.allCases.map { (page: SidebarPage) in page.title }
        XCTAssertTrue(titles.contains("出口分析"), "实际：\(titles)")
    }
}
