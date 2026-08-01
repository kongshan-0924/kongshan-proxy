import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

final class LogsViewGroupingTests: XCTestCase {
    func testGroupsProblemsWithinNetworkTransitionBucketOnce() {
        let logs = [
            entry(id: 1, second: 90, level: .error, message: "route: missing default interface"),
            entry(id: 2, second: 110, level: .warning, message: "dns: lookup failed: i/o timeout"),
            entry(id: 3, second: 121, level: .error, message: "connection: dial tcp: i/o timeout")
        ]

        let groups = LogConnectionGrouping.groups(from: logs)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].host, "网络切换期间")
        XCTAssertEqual(groups[0].entries.map(\.id), logs.prefix(2).map(\.id))
        XCTAssertEqual(groups[0].worstLevel, .error)
        XCTAssertEqual(groups[1].entries.map(\.id), [logs[2].id])
    }

    func testExpectedRuleRejectionDoesNotMakeGroupLookBroken() {
        let rejection = entry(
            id: 7,
            second: 200,
            level: .error,
            message: "connection to ads.example:443 using outbound/block[reject]: operation not permitted"
        )

        let groups = LogConnectionGrouping.groups(from: [rejection])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].worstLevel, .info)
        XCTAssertEqual(groups[0].entries, [rejection], "原始规则拒绝仍需保留在完整日志中")
    }

    private func entry(id: Int, second: TimeInterval, level: CoreLogLevel, message: String) -> LiveLogEntry {
        LiveLogEntry(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            entry: CoreLogEntry(
                level: level,
                message: "[\(id) 0ms] \(message)",
                receivedAt: Date(timeIntervalSinceReferenceDate: second)
            )
        )
    }
}
