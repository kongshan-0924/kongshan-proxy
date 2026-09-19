import AppKit
import KongshanCore
import SwiftUI
import XCTest
@testable import kongshan

/// 真机 2026-09-03 指标流水：仪表盘可见时 CPU 中位 6.3%、其它页 1.5%。差的这一截来自整页 body
/// 直接读速率 / 连接数这类每秒变化的值——任何一个变一下，状态区、六张卡、图表容器整页重排。
/// 钉住两件事：源码层面高频状态不出现在整页作用域；行为层面速率变化不触发整页 body 求值。
@MainActor
final class DashboardObservationScopeTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testHighFrequencyStateIsNotReadInPageScope() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/DashboardView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "struct DashboardView: View {"))
        // 整页作用域到第一个子视图定义为止；之后的每个小视图各自跟踪 Observation。
        let end = try XCTUnwrap(source.range(of: "private struct DashboardTrafficGroup", range: start.upperBound..<source.endIndex))
        let pageScope = String(source[start.upperBound..<end.lowerBound])
        // exitDiagnostics 低频且只在 onAppear 闭包里读一次（不进 Observation 跟踪），不在此列。
        for forbidden in [
            "state.uploadRate", "state.downloadRate", "state.activeConnectionCount", "state.coreMemory",
            "state.lastMetrics", "state.trafficHistory", "state.sessionTotal", "state.sessionUpload",
            "state.sessionDownload"
        ] {
            XCTAssertFalse(pageScope.contains(forbidden), "整页作用域不能读高频状态：\(forbidden)")
        }
    }

    func testTrafficRateChangesDoNotReevaluateWholePage() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-dashboard-scope-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false)
        state.isReady = true

        let hosting = NSHostingView(rootView: AnyView(DashboardView().environment(state)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        pump(0.6)

        let pageBefore = DashboardView.bodyEvaluations
        let rateBefore = DashboardLiveRatePair.bodyEvaluations
        for index in 1...8 {
            state.receiveTrafficForTesting(TrafficSample(up: Int64(index) * 10_240, down: Int64(index) * 40_960))
            pump(0.1)
        }
        hosting.layoutSubtreeIfNeeded()
        pump(0.3)

        XCTAssertGreaterThan(
            DashboardLiveRatePair.bodyEvaluations, rateBefore,
            "速率视图自己必须跟着更新——否则说明更新根本没送达，下一条断言就没有意义"
        )
        XCTAssertEqual(DashboardView.bodyEvaluations, pageBefore, "速率变化不能让整页 body 重新求值")
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
