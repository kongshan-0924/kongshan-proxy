import Foundation
import XCTest
@testable import KongshanCore

final class CrashRestartTests: XCTestCase {
    func testRollingWindowAllowsThreeRestartsAndRejectsFourth() {
        let start = Date(timeIntervalSince1970: 10_000)
        var limiter = CrashRestartLimiter(maxRestarts: 3, window: 10)

        XCTAssertTrue(limiter.allowsRestart(at: start))
        XCTAssertTrue(limiter.allowsRestart(at: start.addingTimeInterval(1)))
        XCTAssertTrue(limiter.allowsRestart(at: start.addingTimeInterval(2)))
        XCTAssertFalse(limiter.allowsRestart(at: start.addingTimeInterval(3)))
        XCTAssertTrue(limiter.allowsRestart(at: start.addingTimeInterval(11)))
    }

    func testProcessExitMonitorReportsExactPIDAndCancelSuppressesOldProcess() async throws {
        let first = Process()
        first.executableURL = URL(fileURLWithPath: "/bin/sleep")
        first.arguments = ["10"]
        try first.run()
        let recorder = ExitPIDRecorder()
        let monitor = ProcessExitMonitor()
        try await monitor.monitor(pid: first.processIdentifier, handler: recorder.append)

        first.terminate()
        first.waitUntilExit()
        try await waitUntil { recorder.values == [first.processIdentifier] }

        let second = Process()
        second.executableURL = URL(fileURLWithPath: "/bin/sleep")
        second.arguments = ["10"]
        try second.run()
        try await monitor.monitor(pid: second.processIdentifier, handler: recorder.append)
        await monitor.cancel()
        second.terminate()
        second.waitUntilExit()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(recorder.values, [first.processIdentifier])
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for process exit event")
    }
}

private final class ExitPIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int32] = []

    var values: [Int32] { lock.withLock { storedValues } }

    func append(_ pid: Int32) {
        lock.withLock { storedValues.append(pid) }
    }
}
