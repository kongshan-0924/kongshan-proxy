import Foundation
import XCTest
@testable import kongshan

/// 失败类运行事件必须带原因。运行事件是持久化、可导出的取证记录；`errorMessage` 只是
/// 一闪而过的 UI 横幅。2026-08-21 两条「配置应用失败，已回滚」因为没有 detail，
/// 两天后完全无法归因——这条守卫防止再退化。
final class RuntimeEventDetailTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryFailureLevelRuntimeEventCarriesDetail() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/AppState.swift"),
            encoding: .utf8
        )
        let lines = source.components(separatedBy: .newlines)

        var offenders: [Int] = []
        for (index, line) in lines.enumerated() where line.contains("recordRuntimeEvent(") {
            // 调用可能跨多行，取本行起 8 行作为一个调用块。
            let block = lines[index..<min(index + 8, lines.count)].joined(separator: "\n")
            let isFailure = block.contains("level: .error") || block.contains("level: .warning")
            guard isFailure else { continue }
            if !block.contains("detail:") { offenders.append(index + 1) }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            "以下行的 error/warning 级运行事件没有 detail，出事时将无法归因：\(offenders)"
        )
    }

    /// 「内核已停止」必须说明触发方，否则区分不出用户主动关闭与异常停止。
    func testKernelStopEventRecordsItsReason() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/AppState.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(#"recordRuntimeEvent(title: "内核已停止", detail: reason"#),
            "内核已停止事件必须记录 reason"
        )
        XCTAssertTrue(
            source.contains("func stop(reason: String"),
            "stop() 必须接受停止原因"
        )
        XCTAssertFalse(
            source.contains("await stop()\n"),
            "所有 stop() 调用点都应显式传入原因"
        )
    }

    /// 运行事件列表要能只看问题：200 条里绝大多数是 info，排查时得能一键滤掉。
    /// 同时过滤结果必须算在 body 之外，避免每次重绘重算。
    func testMessagesViewOffersProblemsOnlyFilter() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/MessagesView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains(#"Toggle("只看问题""#), "运行事件需要只看问题开关")
        XCTAssertTrue(source.contains("private var visibleEvents"), "过滤结果要提取成属性，不在 body 里重算")
        XCTAssertTrue(source.contains("$0.level != .info"), "只看问题应保留 warning 与 error")
        XCTAssertTrue(source.contains("if let detail = event.detail"), "事件详情必须渲染出来")
    }
}
