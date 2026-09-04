import Foundation
import XCTest
@testable import kongshan

/// 连接页与仪表盘合用一条 `/connections` 订阅。
///
/// 这条性质断了**不会有任何报错**：两条订阅同时跑只是 CPU 悄悄翻倍
/// （真机 2026-09-04 连接页开着时均值 3~7.7%、主线程仅占 48%，另一半正是重复解析）；
/// 而如果合流后忘了喂总量，会话累计流量会静静地少算。两头都要钉住。
final class ConnectionFeedWiringTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: "Sources/kongshan/\(name)"), encoding: .utf8)
    }

    func testConnectionsPageTakesOverTheSharedSubscription() throws {
        let state = try source("AppState.swift")
        XCTAssertTrue(
            state.contains("connectionsFeedActive = true"),
            "连接页开启时必须标记接管，否则仪表盘那条 /connections 会同时跑"
        )
        XCTAssertTrue(
            state.contains("connectionsFeedActive = false"),
            "连接页关闭时必须交还，否则总量流再也起不来"
        )
        XCTAssertTrue(
            state.contains("guard !connectionsFeedActive, dashboardConnectionTask == nil else { return }"),
            "仪表盘的 /connections 订阅必须以「连接页没在接管」为前提"
        )
    }

    func testFeedLoopStillFeedsAuthoritativeTotals() throws {
        let state = try source("AppState.swift")
        let start = try XCTUnwrap(state.range(of: "func startConnectionsMonitoring()"))
        let end = try XCTUnwrap(state.range(of: "func stopConnectionsMonitoring()", range: start.upperBound..<state.endIndex))
        let loop = String(state[start.upperBound..<end.lowerBound])
        XCTAssertTrue(loop.contains("connectionFeedStream"), "连接页要订阅合流后的那条流")
        XCTAssertTrue(
            loop.contains("receiveConnectionSnapshot(feed.snapshot)"),
            "接管期间必须由这条流继续喂会话累计量，否则断掉不会报错、只会少算"
        )
        // 喂总量这一步不能被「窗口不可见」的早退挡在后面。
        let snapshotIndex = try XCTUnwrap(loop.range(of: "receiveConnectionSnapshot(feed.snapshot)")).lowerBound
        if let guardIndex = loop.range(of: "guard self.windowContentIsVisible")?.lowerBound {
            XCTAssertLessThan(
                snapshotIndex, guardIndex,
                "累计量必须在可见性早退之前喂——窗口不可见时流量照样在走"
            )
        }
    }
}
