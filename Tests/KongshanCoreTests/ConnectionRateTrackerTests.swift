import Foundation
import XCTest
@testable import KongshanCore

final class ConnectionRateTrackerTests: XCTestCase {
    func testFirstSnapshotHasZeroRates() {
        var tracker = ConnectionRateTracker()

        let live = tracker.update([connection(id: "a", upload: 100, download: 200)], at: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(live.first?.uploadRate, 0)
        XCTAssertEqual(live.first?.downloadRate, 0)
    }

    func testCalculatesByteDeltaPerSecond() {
        var tracker = ConnectionRateTracker()
        _ = tracker.update([connection(id: "a", upload: 100, download: 200)], at: Date(timeIntervalSince1970: 10))

        let live = tracker.update([connection(id: "a", upload: 300, download: 700)], at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(live.first?.uploadRate, 100)
        XCTAssertEqual(live.first?.downloadRate, 250)
        XCTAssertEqual(live.totalRate, 350)
    }

    func testCounterRollbackDoesNotProduceNegativeRate() {
        var tracker = ConnectionRateTracker()
        _ = tracker.update([connection(id: "a", upload: 500, download: 800)], at: Date(timeIntervalSince1970: 10))

        let live = tracker.update([connection(id: "a", upload: 20, download: 30)], at: Date(timeIntervalSince1970: 11))

        XCTAssertEqual(live.first?.uploadRate, 0)
        XCTAssertEqual(live.first?.downloadRate, 0)
    }

    func testRemovedConnectionDoesNotReuseStaleSample() {
        var tracker = ConnectionRateTracker()
        _ = tracker.update([connection(id: "a", upload: 100, download: 100)], at: Date(timeIntervalSince1970: 10))
        _ = tracker.update([], at: Date(timeIntervalSince1970: 11))

        let live = tracker.update([connection(id: "a", upload: 1_000, download: 1_000)], at: Date(timeIntervalSince1970: 12))

        XCTAssertEqual(live.first?.totalRate, 0)
    }

    private func connection(id: String, upload: Int64, download: Int64) -> ConnectionDetail {
        ConnectionDetail(payload: [
            "id": id,
            "upload": NSNumber(value: upload),
            "download": NSNumber(value: download),
            "metadata": ["host": "example.com", "network": "tcp"]
        ])
    }
}
