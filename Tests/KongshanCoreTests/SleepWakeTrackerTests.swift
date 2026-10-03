import Foundation
import XCTest
@testable import KongshanCore

/// 睡眠 / 暗唤醒感知。真机 2026-10-03：暗唤醒每 15 分钟一次、每次醒 2～7 秒，
/// 期间的失败让最近 200 条运行事件里出了 70 条误报。
final class SleepWakeTrackerTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    func testAwakeTimeNeverCountsAsSleepNoMatterHowSparseTheObservations() {
        var tracker = SleepWakeTracker()
        tracker.observe(.init(monotonic: 100, uptime: 50), at: origin)
        // 一小时没观测，但两只时钟一起走：没睡过。
        XCTAssertFalse(tracker.observe(.init(monotonic: 3_700, uptime: 3_650), at: origin.addingTimeInterval(3_600)))
        XCTAssertFalse(tracker.isQuiet(at: origin.addingTimeInterval(3_600)))
    }

    /// 暗唤醒：睡了 15 分钟、醒来第一次观测就要察觉，并在之后 90 秒内保持安静。
    func testDarkWakeStartsAQuietPeriod() {
        var tracker = SleepWakeTracker()
        tracker.observe(.init(monotonic: 100, uptime: 50), at: origin)
        let woke = origin.addingTimeInterval(900)
        XCTAssertTrue(tracker.observe(.init(monotonic: 1_000.5, uptime: 50.5), at: woke))
        XCTAssertTrue(tracker.isQuiet(at: woke))
        XCTAssertTrue(tracker.isQuiet(at: woke.addingTimeInterval(SleepWakeTracker.quietAfterWake)))
        XCTAssertFalse(tracker.isQuiet(at: woke.addingTimeInterval(SleepWakeTracker.quietAfterWake + 1)),
                       "醒来后网络真坏了，过了安静期照样要报")
    }

    func testClockJitterIsNotSleep() {
        var tracker = SleepWakeTracker()
        tracker.observe(.init(monotonic: 100, uptime: 50), at: origin)
        XCTAssertFalse(tracker.observe(.init(monotonic: 115, uptime: 61), at: origin.addingTimeInterval(15)), "差 4 秒以内不算")
        XCTAssertNil(tracker.quietUntil)
    }

    /// 连着几次暗唤醒：安静期跟着最近一次往后延，不会被更早的一次截短。
    func testRepeatedWakesExtendTheQuietPeriod() {
        var tracker = SleepWakeTracker()
        tracker.observe(.init(monotonic: 0, uptime: 0), at: origin)
        tracker.observe(.init(monotonic: 900, uptime: 5), at: origin.addingTimeInterval(900))
        tracker.observe(.init(monotonic: 1_800, uptime: 10), at: origin.addingTimeInterval(1_800))
        XCTAssertEqual(tracker.quietUntil, origin.addingTimeInterval(1_800 + SleepWakeTracker.quietAfterWake))
    }

    func testRealClocksAdvanceTogetherWhileAwake() {
        let first = SleepWakeTracker.Reading.current()
        let second = SleepWakeTracker.Reading.current()
        XCTAssertGreaterThanOrEqual(second.monotonic, first.monotonic)
        XCTAssertGreaterThanOrEqual(second.uptime, first.uptime)
        XCTAssertLessThan(abs((second.monotonic - first.monotonic) - (second.uptime - first.uptime)), 1)
    }
}
