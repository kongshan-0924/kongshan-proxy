import XCTest
@testable import KongshanCore

final class NetworkThroughputTests: XCTestCase {
    // MARK: - 速率计算（纯逻辑）

    func testFirstSampleHasNoBaseline() {
        var calculator = ThroughputRateCalculator()
        let rate = calculator.rate(from: InterfaceCounters(inputBytes: 1_000, outputBytes: 500), at: Date())
        XCTAssertEqual(rate.upload, 0)
        XCTAssertEqual(rate.download, 0)
    }

    func testComputesRateFromDelta() {
        var calculator = ThroughputRateCalculator()
        let t0 = Date()
        _ = calculator.rate(from: InterfaceCounters(inputBytes: 1_000, outputBytes: 500), at: t0)
        let rate = calculator.rate(
            from: InterfaceCounters(inputBytes: 3_000, outputBytes: 1_500),
            at: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(rate.download, 1_000, "(3000-1000)/2")
        XCTAssertEqual(rate.upload, 500, "(1500-500)/2")
    }

    /// 拔插网线 / 切 Wi-Fi 会让接口计数器归零。不能算出一个负速率或天文数字。
    func testCounterResetYieldsZeroAndRebaselines() {
        var calculator = ThroughputRateCalculator()
        let t0 = Date()
        _ = calculator.rate(from: InterfaceCounters(inputBytes: 10_000, outputBytes: 10_000), at: t0)

        let afterReset = calculator.rate(
            from: InterfaceCounters(inputBytes: 100, outputBytes: 100),
            at: t0.addingTimeInterval(1)
        )
        XCTAssertEqual(afterReset.download, 0, "计数器回退这一轮给 0")

        let next = calculator.rate(
            from: InterfaceCounters(inputBytes: 1_100, outputBytes: 600),
            at: t0.addingTimeInterval(2)
        )
        XCTAssertEqual(next.download, 1_000, "下一轮以新基线正常计算")
        XCTAssertEqual(next.upload, 500)
    }

    /// 睡眠唤醒后两次采样可能隔几小时，算出来的"平均值"没有意义。
    func testIgnoresImplausibleIntervals() {
        var calculator = ThroughputRateCalculator()
        let t0 = Date()
        _ = calculator.rate(from: InterfaceCounters(inputBytes: 0, outputBytes: 0), at: t0)

        let tooLong = calculator.rate(
            from: InterfaceCounters(inputBytes: 1_000_000, outputBytes: 0),
            at: t0.addingTimeInterval(3_600)
        )
        XCTAssertEqual(tooLong.download, 0)

        var fresh = ThroughputRateCalculator()
        _ = fresh.rate(from: InterfaceCounters(inputBytes: 0, outputBytes: 0), at: t0)
        let tooShort = fresh.rate(
            from: InterfaceCounters(inputBytes: 1_000_000, outputBytes: 0),
            at: t0.addingTimeInterval(0.01)
        )
        XCTAssertEqual(tooShort.download, 0, "间隔过小除出来是尖峰")
    }

    func testResetClearsBaseline() {
        var calculator = ThroughputRateCalculator()
        let t0 = Date()
        _ = calculator.rate(from: InterfaceCounters(inputBytes: 1_000, outputBytes: 0), at: t0)
        calculator.reset()
        let rate = calculator.rate(from: InterfaceCounters(inputBytes: 5_000, outputBytes: 0), at: t0.addingTimeInterval(1))
        XCTAssertEqual(rate.download, 0, "reset 后应重新建立基线")
    }

    // MARK: - 真机读数

    /// 真读一次网卡计数器。这是唯一能验证 sysctl 走位、结构体偏移与接口名过滤都对的方式——
    /// 纯逻辑测试再全也覆盖不到 `NET_RT_IFLIST2` 的内存布局。
    func testReadsPhysicalCountersOnThisMachine() throws {
        guard let counters = NetworkThroughput.physicalCounters() else {
            throw XCTSkip("本机没有活动的 en* 接口")
        }
        XCTAssertGreaterThan(counters.inputBytes + counters.outputBytes, 0)

        // 计数器必须单调增：隔一会儿再读一次，不能变小。
        let later = try XCTUnwrap(NetworkThroughput.physicalCounters())
        XCTAssertGreaterThanOrEqual(later.inputBytes, counters.inputBytes)
        XCTAssertGreaterThanOrEqual(later.outputBytes, counters.outputBytes)
    }
}
