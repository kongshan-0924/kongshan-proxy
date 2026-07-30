import XCTest
@testable import KongshanCore

final class SessionTrafficTests: XCTestCase {
    func testAccumulatesMonotonicCounters() {
        var accumulator = SessionTrafficAccumulator()
        XCTAssertEqual(accumulator.total, 0)

        accumulator.record(uploadTotal: 100, downloadTotal: 900)
        XCTAssertEqual(accumulator.upload, 100)
        XCTAssertEqual(accumulator.download, 900)
        XCTAssertEqual(accumulator.total, 1_000)

        accumulator.record(uploadTotal: 250, downloadTotal: 2_000)
        XCTAssertEqual(accumulator.upload, 250, "单调递增时直接取内核读数，不要相加")
        XCTAssertEqual(accumulator.download, 2_000)
    }

    /// 核心场景：改设置 / 崩溃自愈 / 切配置都会重启内核，内核计数器随之归零。
    /// 会话累计必须跨过去，否则用户会看到流量突然掉回从头。
    func testCarriesOverAcrossKernelRestart() {
        var accumulator = SessionTrafficAccumulator()
        accumulator.record(uploadTotal: 1_000, downloadTotal: 5_000)

        // 内核重启：两个计数器都归零，然后重新往上走。
        accumulator.record(uploadTotal: 0, downloadTotal: 0)
        XCTAssertEqual(accumulator.upload, 1_000, "归零瞬间不能掉数")
        XCTAssertEqual(accumulator.download, 5_000)

        accumulator.record(uploadTotal: 30, downloadTotal: 70)
        XCTAssertEqual(accumulator.upload, 1_030)
        XCTAssertEqual(accumulator.download, 5_070)
        XCTAssertEqual(accumulator.total, 6_100)
    }

    func testSurvivesRepeatedRestarts() {
        var accumulator = SessionTrafficAccumulator()
        for _ in 0..<5 {
            accumulator.record(uploadTotal: 10, downloadTotal: 20)
            accumulator.record(uploadTotal: 0, downloadTotal: 0)
        }
        XCTAssertEqual(accumulator.total, 5 * 30)
    }

    /// 只有一个方向回退也要判定为重启：空闲会话可能上行有量、下行一直是 0，
    /// 要求两个同时回退会漏判，那一段流量就白丢了。
    func testDetectsRestartWhenOnlyOneCounterRegresses() {
        var accumulator = SessionTrafficAccumulator()
        accumulator.record(uploadTotal: 500, downloadTotal: 0)
        accumulator.record(uploadTotal: 0, downloadTotal: 0)
        accumulator.record(uploadTotal: 10, downloadTotal: 0)

        XCTAssertEqual(accumulator.upload, 510)
    }

    func testIgnoresNegativeReadings() {
        var accumulator = SessionTrafficAccumulator()
        accumulator.record(uploadTotal: 100, downloadTotal: 100)
        accumulator.record(uploadTotal: -1, downloadTotal: 50)

        XCTAssertEqual(accumulator.total, 200, "坏数据不该改动基线")
    }

    func testResetClearsEverything() {
        var accumulator = SessionTrafficAccumulator()
        accumulator.record(uploadTotal: 1_000, downloadTotal: 1_000)
        accumulator.record(uploadTotal: 0, downloadTotal: 0)
        accumulator.record(uploadTotal: 5, downloadTotal: 5)
        XCTAssertGreaterThan(accumulator.total, 0)

        accumulator.reset()
        XCTAssertEqual(accumulator.total, 0)
        XCTAssertEqual(accumulator.upload, 0)
        XCTAssertEqual(accumulator.download, 0)
    }

    /// 快照要把内核给的累计量带上来——之前 `/connections` 的这两个字段被整个丢掉了，
    /// 于是根本没有权威累计量可用。
    func testSnapshotCarriesTotals() {
        let snapshot = ConnectionSnapshot(
            connectionCount: 3,
            memory: 1_024,
            uploadTotal: 111,
            downloadTotal: 222
        )
        XCTAssertEqual(snapshot.uploadTotal, 111)
        XCTAssertEqual(snapshot.downloadTotal, 222)
    }
}

/// 首次采样的速率。
///
/// 速率原本靠相邻两次采样的字节差，于是每条连接第一次出现时只能是 0 → 界面显示 `—`。
/// 短命连接（一次请求就关）往往只被采样到一次，明明在传数据却始终 `—`，
/// 用户看到的就是"连接页的统计数据不对"。
extension SessionTrafficTests {
    private func detail(id: String, upload: Int64, download: Int64, start: Date?) -> ConnectionDetail {
        var payload: [String: Any] = [
            "id": id,
            "upload": NSNumber(value: upload),
            "download": NSNumber(value: download),
            "metadata": ["host": "example.com", "destinationPort": "443"]
        ]
        if let start {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            payload["start"] = formatter.string(from: start)
        }
        return ConnectionDetail(payload: payload)
    }

    func testFirstSampleUsesConnectionAgeForRate() {
        let now = Date()
        var tracker = ConnectionRateTracker()
        // 建立 2 秒、已传 2000 字节 → 平均 1000 B/s。
        let live = tracker.update([detail(id: "a", upload: 0, download: 2_000, start: now.addingTimeInterval(-2))], at: now)

        XCTAssertEqual(live.count, 1)
        // 容差断言而不是等值：start 经 ISO8601 往返会丢掉亚毫秒精度，
        // 实际 elapsed 是 2.0001 之类，2000/2.0001 截断成 999。
        // 精确到个位的断言在这里只会变成一条偶发失败的测试。
        XCTAssertEqual(Double(live[0].downloadRate), 1_000, accuracy: 20)
        XCTAssertEqual(live[0].uploadRate, 0, "上行没有字节就该是 0")
    }

    func testFirstSampleFallsBackToZeroWithoutStart() {
        var tracker = ConnectionRateTracker()
        let live = tracker.update([detail(id: "a", upload: 0, download: 2_000, start: nil)], at: Date())
        XCTAssertEqual(live[0].downloadRate, 0, "缺 start 时宁可显示 — 也别编一个数")
    }

    /// 刚建立的连接除出来会是个虚高的尖峰，不如不显示。
    func testFirstSampleIgnoresVeryYoungConnections() {
        let now = Date()
        var tracker = ConnectionRateTracker()
        let live = tracker.update([detail(id: "a", upload: 0, download: 1_000_000, start: now.addingTimeInterval(-0.05))], at: now)
        XCTAssertEqual(live[0].downloadRate, 0)
    }

    /// 第二次采样起仍然走差值，不能被首帧逻辑顶掉。
    func testSubsequentSamplesUseDelta() {
        let start = Date().addingTimeInterval(-10)
        var tracker = ConnectionRateTracker()
        let t0 = Date()
        _ = tracker.update([detail(id: "a", upload: 0, download: 1_000, start: start)], at: t0)
        let live = tracker.update(
            [detail(id: "a", upload: 0, download: 3_000, start: start)],
            at: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(
            Double(live[0].downloadRate),
            1_000,
            accuracy: 20,
            "(3000-1000)/2 = 1000，走差值而不是 3000/12"
        )
    }

    func testStartIsParsedFromISO8601WithFractionalSeconds() {
        let node = ConnectionDetail(payload: [
            "id": "x",
            "start": "2026-07-30T12:00:00.123456789+08:00",
            "metadata": ["host": "a.example.com"]
        ])
        XCTAssertNotNil(node.start, "内核给的是带小数秒的 ISO8601，必须能解析")
    }
}
