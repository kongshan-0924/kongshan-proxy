import Foundation
import KongshanCore
import XCTest
@testable import kongshan

final class SubscriptionUpdateSchedulerTests: XCTestCase {
    func testDefaultsAndValidationEnforceOneToOneHundredSixtyEightHours() throws {
        XCTAssertEqual(SubscriptionUpdateSettings.defaults.intervalHours, 24)
        XCTAssertTrue(SubscriptionUpdateSettings.defaults.enabled)
        XCTAssertThrowsError(
            try SubscriptionUpdateSettings(enabled: true, intervalHours: 0).validated()
        )
        XCTAssertThrowsError(
            try SubscriptionUpdateSettings(enabled: true, intervalHours: 169).validated()
        )
        XCTAssertEqual(
            try SubscriptionUpdateSettings(enabled: false, intervalHours: 12).validated(),
            SubscriptionUpdateSettings(enabled: false, intervalHours: 12)
        )
    }

    func testNextUpdateUsesEarliestSubscriptionAndNeverPredatesNowForNeverUpdatedSource() {
        let now = Date(timeIntervalSince1970: 10_000)
        let sources = [
            SubscriptionSource(
                name: "new",
                url: URL(string: "https://example.com/new")!,
                lastUpdatedAt: nil
            ),
            SubscriptionSource(
                name: "old",
                url: URL(string: "https://example.com/old")!,
                lastUpdatedAt: now.addingTimeInterval(-1_000)
            )
        ]

        XCTAssertEqual(
            SubscriptionUpdateScheduler.nextUpdateDate(
                sources: sources,
                settings: .defaults,
                now: now
            ),
            now
        )
        XCTAssertNil(SubscriptionUpdateScheduler.nextUpdateDate(
            sources: sources,
            settings: SubscriptionUpdateSettings(enabled: false, intervalHours: 24),
            now: now
        ))
        XCTAssertNil(SubscriptionUpdateScheduler.nextUpdateDate(
            sources: [],
            settings: .defaults,
            now: now
        ))
    }

    func testOverdueScheduleFiresImmediatelyWithoutSleeping() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let sleep = SchedulerSleepRecorder()
        let fired = SchedulerActionRecorder()
        let scheduler = SubscriptionUpdateScheduler(now: { now }, sleeper: sleep.sleep)
        let source = SubscriptionSource(
            name: "due",
            url: URL(string: "https://example.com/sub")!,
            lastUpdatedAt: now.addingTimeInterval(-7_200)
        )

        let scheduledAt = await scheduler.schedule(
            sources: [source],
            settings: SubscriptionUpdateSettings(enabled: true, intervalHours: 1),
            action: fired.fire
        )

        XCTAssertEqual(scheduledAt, now)
        try await waitUntil { fired.count == 1 }
        XCTAssertTrue(sleep.delays.isEmpty)
    }

    func testRescheduleCancelsOldOneShotSleepAndCancelStopsReplacement() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let sleep = SchedulerSleepRecorder()
        let scheduler = SubscriptionUpdateScheduler(now: { now }, sleeper: sleep.sleep)
        let source = SubscriptionSource(
            name: "future",
            url: URL(string: "https://example.com/sub")!,
            lastUpdatedAt: now
        )

        _ = await scheduler.schedule(
            sources: [source],
            settings: SubscriptionUpdateSettings(enabled: true, intervalHours: 1),
            action: {}
        )
        try await waitUntil { sleep.delays == [3_600] }

        _ = await scheduler.schedule(
            sources: [source],
            settings: SubscriptionUpdateSettings(enabled: true, intervalHours: 2),
            action: {}
        )
        try await waitUntil { sleep.delays == [3_600, 7_200] && sleep.cancellationCount == 1 }

        await scheduler.cancel()
        try await waitUntil { sleep.cancellationCount == 2 }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for scheduler state", file: file, line: line)
    }
}

private final class SchedulerSleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedDelays: [TimeInterval] = []
    private var storedCancellationCount = 0

    var delays: [TimeInterval] { lock.withLock { storedDelays } }
    var cancellationCount: Int { lock.withLock { storedCancellationCount } }

    func sleep(_ delay: TimeInterval) async throws {
        lock.withLock { storedDelays.append(delay) }
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(60))
        } onCancel: {
            lock.withLock { storedCancellationCount += 1 }
        }
    }
}

private final class SchedulerActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func fire() async {
        lock.withLock { storedCount += 1 }
    }
}
