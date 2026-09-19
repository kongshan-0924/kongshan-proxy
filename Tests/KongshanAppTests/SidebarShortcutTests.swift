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

    /// 2026-09-17 信息架构重构：10 页 → 8 页，⌘1~⌘8 全覆盖。
    /// 这条仍守着「别让页数悄悄爬过 9」——超出的页拿不到快捷键。
    func testPageCountStaysWithinShortcutRange() {
        XCTAssertEqual(SidebarPage.allCases.count, 8)
        XCTAssertLessThanOrEqual(
            SidebarPage.allCases.count, 9,
            "超过 9 页就有页面拿不到 ⌘N；要么合并，要么显式接受并改这条断言"
        )
    }

    /// 出口分析的功能必须在（原为独立页，重构后是「诊断」页的第一个分段）。
    /// 断言落在实现类型而不是页标题上：页可以改名、可以被合并，
    /// 但「看当前出口 IP 与站点可达性」这件事不能消失。
    func testExitAnalysisSurvivesAsDiagnosticsSegment() throws {
        let titles: [String] = SidebarPage.allCases.map { (page: SidebarPage) in page.title }
        XCTAssertTrue(titles.contains("诊断"), "实际：\(titles)")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appending(path: "Sources/kongshan/DiagnosticsView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("ExitAnalysisView()"), "诊断页必须仍然渲染出口分析")
        XCTAssertTrue(source.contains("case exit"), "出口分析必须是诊断页的一个分段")
    }
}
