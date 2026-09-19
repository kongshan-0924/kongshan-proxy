import KongshanCore
import SwiftUI
import XCTest
@testable import kongshan

/// 量「一次速率更新引发多少次速率视图 body 求值」。
///
/// v0.1.108 把状态卡头部改成了 `ViewThatFits`，而两个候选分支里都放了
/// `DashboardLiveRatePair`。ViewThatFits 要测量每个候选才能选出合适的那个，
/// 于是每秒一次的速率更新可能被放大成多次求值——真机 09-10 同条件 CPU
/// 中位数从 1.7~2.1% 跳到 4.09%，这是头号嫌疑。
@MainActor
final class RateUpdateCostTests: XCTestCase {
    func testRateUpdateCostPerTick() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-ratecost-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false)
        state.isReady = true

        let hosting = NSHostingView(rootView: AnyView(DashboardView().environment(state)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        pump(0.6)

        let ticks = 20
        let before = DashboardLiveRatePair.bodyEvaluations
        for index in 1...ticks {
            state.receiveTrafficForTesting(TrafficSample(up: Int64(index) * 10_240, down: Int64(index) * 40_960))
            pump(0.05)
        }
        hosting.layoutSubtreeIfNeeded()
        pump(0.3)
        let evals = DashboardLiveRatePair.bodyEvaluations - before
        let perTick = Double(evals) / Double(ticks)

        // 实测基线：0.55/次（v0.1.107 及之前，以及改回按宽度决策之后）。
        // 用 `ViewThatFits` 那版是 1.65/次。阈值取 1.0：既容得下正常抖动，
        // 又能挡住"把每秒变化的视图放进需要逐个测量的容器里"这类改动。
        XCTAssertLessThan(
            perTick, 1.0,
            "每次速率更新引发 \(perTick) 次速率视图求值——高频视图被放进了要逐候选测量的容器里？"
        )
        XCTAssertGreaterThan(evals, 0, "一次都没求值说明更新没送达，上面的断言就没有意义")
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
