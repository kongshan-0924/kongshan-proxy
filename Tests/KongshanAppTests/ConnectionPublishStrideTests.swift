import XCTest
@testable import kongshan

/// P1：连接页把列表推给界面的频率随连接数降低。
///
/// 实测（2026-09-17 审计，metrics.ndjson 403 个样本）连接页 CPU 随连接数放大：
/// 21–50 条中位 1.29% → 51–100 条 6.18% → >100 条 8.69%（峰值 12.63%）。
/// 开销不在排序或等值判断，而在 SwiftUI `Table` 每秒 diff 上百行。
@MainActor
final class ConnectionPublishStrideTests: XCTestCase {
    /// 连接少时必须保持每秒一帧——实时感正是这一页的价值。
    func testSmallConnectionCountsStayRealtime() {
        for count in [0, 1, 20, 50] {
            XCTAssertEqual(AppState.connectionPublishStride(for: count), 1, "\(count) 条时不该降频")
        }
    }

    /// 阈值取自实测拐点：50 条以内 1.29%，越过就跳到 6% 以上。
    func testStrideIncreasesPastMeasuredKnee() {
        XCTAssertEqual(AppState.connectionPublishStride(for: 51), 2)
        XCTAssertEqual(AppState.connectionPublishStride(for: 150), 2)
        XCTAssertEqual(AppState.connectionPublishStride(for: 151), 3)
        XCTAssertEqual(AppState.connectionPublishStride(for: 1_000), 3)
    }

    /// 单调不减：连接越多只会更省，不会反过来更费。
    func testStrideIsMonotonic() {
        var previous = 0
        for count in stride(from: 0, through: 400, by: 10) {
            let value = AppState.connectionPublishStride(for: count)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }
}
