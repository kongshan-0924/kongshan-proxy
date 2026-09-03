import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// CPU 异常持续时自动采一份调用栈：只在「持续」阶段、10 分钟一份、路径写进事件；失败也要留痕。
@MainActor
final class CPUSampleWiringTests: XCTestCase {
    private func report(_ phase: CPUAnomalyReport.Phase) -> CPUAnomalyReport {
        CPUAnomalyReport(
            phase: phase,
            startedAt: Date().addingTimeInterval(-278),
            observedUntil: Date(),
            averagePercent: 24.8,
            peakPercent: 39.9,
            userShare: 0.98,
            cpuSecondsConsumed: 68.8,
            peakResidentBytes: 85 * 1_048_576,
            peakThreadCount: 8,
            mainThreadShare: 0.96
        )
    }

    private func makeState() -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-cpu-sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false), root)
    }

    func testOngoingAnomalyCapturesOneSampleAndRecordsWhereItWent() async throws {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SampleRunRecorder()
        state.cpuSampleRunner = recorder.run

        state.record(report(.ongoing), logLinesInWindow: 456)
        let task = try XCTUnwrap(state.cpuSampleTask, "持续阶段必须起采样")
        await task.value

        let calls = recorder.recorded
        XCTAssertEqual(calls.count, 1)
        let arguments = try XCTUnwrap(calls.first)
        XCTAssertEqual(arguments.prefix(4), [String(ProcessInfo.processInfo.processIdentifier), "5", "-mayDie", "-file"])
        let output = try XCTUnwrap(arguments.last)
        XCTAssertTrue(output.hasPrefix(root.appending(path: "samples").path), output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "samples").path), "采样目录要先建好")

        let ongoing = try XCTUnwrap(state.runtimeEvents.first { $0.title == "CPU 占用持续偏高" })
        XCTAssertTrue(ongoing.detail?.contains("调用栈采样") == true, ongoing.detail ?? "")
        XCTAssertTrue(ongoing.detail?.contains(output) == true, "事件里要写明文件在哪：\(ongoing.detail ?? "")")
        XCTAssertTrue(state.runtimeEvents.contains { $0.title == "已保存 CPU 调用栈采样" })

        // 同一次爆发再报一次：10 分钟内不再采；回落更不采。
        state.record(report(.ongoing), logLinesInWindow: 0)
        XCTAssertNil(state.cpuSampleTask)
        state.record(report(.ended), logLinesInWindow: 0)
        XCTAssertNil(state.cpuSampleTask)
        XCTAssertEqual(recorder.recorded.count, 1)
        let ended = try XCTUnwrap(state.runtimeEvents.last { $0.title == "CPU 占用已回落" })
        XCTAssertFalse(ended.detail?.contains("调用栈采样") == true)
    }

    func testSampleFailureIsRecordedNotSwallowed() async throws {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SampleRunRecorder()
        recorder.shouldFail = true
        state.cpuSampleRunner = recorder.run

        state.record(report(.ongoing), logLinesInWindow: 0)
        let task = try XCTUnwrap(state.cpuSampleTask)
        await task.value

        let failure = try XCTUnwrap(state.runtimeEvents.first { $0.title == "CPU 调用栈采样失败" })
        XCTAssertTrue(failure.detail?.contains("退出码 1") == true, failure.detail ?? "")
        XCTAssertFalse(state.runtimeEvents.contains { $0.title == "已保存 CPU 调用栈采样" })
    }
}

private final class SampleRunRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    var shouldFail = false

    func run(_ arguments: [String]) throws {
        lock.withLock { calls.append(arguments) }
        if shouldFail { throw CPUSampleCaptureError.toolFailed(1) }
    }

    var recorded: [[String]] {
        lock.withLock { calls }
    }
}
