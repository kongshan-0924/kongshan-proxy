import XCTest
@testable import KongshanCore
@testable import kongshan

final class DashboardMetricsCoordinatorTests: XCTestCase {
    func testConnectionCardsPublishAtHalfStreamRate() {
        var coordinator = DashboardMetricsCoordinator()
        let snapshot = ConnectionSnapshot(connectionCount: 3, memory: 4, uploadTotal: 1, downloadTotal: 2)

        let decisions = (0..<6).map { _ in coordinator.shouldPublishConnectionSnapshot(snapshot) }
        XCTAssertEqual(decisions, [true, true, false, true, false, true])
    }

    func testTrafficChartPublishesAtQuarterRateAndResetsWhenHidden() {
        var coordinator = DashboardMetricsCoordinator()
        let decisions = (0..<5).map { _ -> Bool in
            _ = coordinator.shouldPublishTrafficRates()
            return coordinator.shouldPublishTrafficPoint(isDashboardVisible: true)
        }
        XCTAssertEqual(decisions, [true, false, false, true, false])
        XCTAssertFalse(coordinator.shouldPublishTrafficPoint(isDashboardVisible: false))
        _ = coordinator.shouldPublishTrafficRates()
        XCTAssertTrue(coordinator.shouldPublishTrafficPoint(isDashboardVisible: true))
    }

    func testSpeedTestProgressIsStableForEmptyAndPartialRuns() {
        XCTAssertEqual(SpeedTestProgress().fraction, 0)
        XCTAssertEqual(SpeedTestProgress(completed: 3, total: 8).fraction, 0.375)
        XCTAssertEqual(SpeedTestProgress(completed: 3, total: 8).label, "3 / 8")
    }
}
