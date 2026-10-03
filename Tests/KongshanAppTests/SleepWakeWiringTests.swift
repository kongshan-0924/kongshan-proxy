import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 暗唤醒误报的接线回归：醒来后的安静期里失败不进检测器，过了安静期照常统计。
///
/// 真机 2026-10-03：合盖期间每 15 分钟暗唤醒一次、每次醒 2～7 秒，网络还没恢复，后台请求集中失败，
/// 最近 200 条运行事件里 70 条「DNS 解析持续超时 / 本机网络不通 / 节点建连失败偏多」都是这么来的。
@MainActor
final class SleepWakeWiringTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var date = Date(timeIntervalSince1970: 1_790_000_000)
        private var reading = SleepWakeTracker.Reading(monotonic: 1_000, uptime: 500)

        var now: Date { lock.withLock { date } }
        var clocks: SleepWakeTracker.Reading { lock.withLock { reading } }

        /// 醒着过了 `seconds` 秒：墙钟与两只单调时钟一起走。
        func stayAwake(_ seconds: TimeInterval) {
            lock.withLock {
                date = date.addingTimeInterval(seconds)
                reading.monotonic += seconds
                reading.uptime += seconds
            }
        }

        /// 睡了 `seconds` 秒：睡眠时停走的那只不动。
        func sleep(_ seconds: TimeInterval) {
            lock.withLock {
                date = date.addingTimeInterval(seconds)
                reading.monotonic += seconds
            }
        }
    }

    private func makeState(_ box: Box) -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-sleep-\(UUID().uuidString)", directoryHint: .isDirectory)
        let state = AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            now: { box.now },
            automaticallyInitialize: false
        )
        state.sleepClockReading = { box.clocks }
        return (state, root)
    }

    private func failureEntry(id: Int) -> CoreLogEntry {
        CoreLogEntry(
            level: .error,
            message: "[\(id) 3.19s] connection: open connection to x\(id).example.invalid:443 using "
                + "outbound/anytls[node-placeholder]: failed to create session: EOF",
            receivedAt: Date()
        )
    }

    func testFailuresRightAfterADarkWakeAreNotCountedButLaterOnesAre() throws {
        let box = Box()
        let (state, root) = makeState(box)
        defer { try? FileManager.default.removeItem(at: root) }
        state.stopLogMonitoring()

        state.receiveLog(failureEntry(id: 1))   // 睡前最后一次观测（一行失败，远不到门槛）
        box.sleep(900)                          // 合盖 15 分钟后暗唤醒
        for index in 0..<40 {
            state.receiveLog(failureEntry(id: 100 + index))
            box.stayAwake(0.1)
        }
        XCTAssertNil(state.finishAnomalyWindowsForTesting(), "暗唤醒那几秒的 40 次失败不能进统计")

        // 醒着过了安静期，网络还是不通：照常统计、照常报。
        box.stayAwake(SleepWakeTracker.quietAfterWake + 1)
        for index in 0..<40 {
            state.receiveLog(failureEntry(id: 1_000 + index))
            box.stayAwake(0.1)
        }
        let report = try XCTUnwrap(state.finishAnomalyWindowsForTesting(), "醒来后网络真坏了必须照报")
        XCTAssertEqual(report.failures, 40)
    }

    /// 没睡过时一切照旧——两只时钟一起走，不能误判成睡眠把正常的告警吞掉。
    func testNoSleepNoQuietPeriod() throws {
        let box = Box()
        let (state, root) = makeState(box)
        defer { try? FileManager.default.removeItem(at: root) }
        state.stopLogMonitoring()

        for index in 0..<30 {
            state.receiveLog(failureEntry(id: 2_000 + index))
            box.stayAwake(0.5)
        }
        XCTAssertEqual(state.finishAnomalyWindowsForTesting()?.failures, 30)
    }
}
