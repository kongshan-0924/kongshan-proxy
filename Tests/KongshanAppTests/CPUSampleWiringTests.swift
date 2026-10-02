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
        // 回落的总结仍指向本段那份采样：短时爆发只有这一条记录，路径不能丢。
        let ended = try XCTUnwrap(state.runtimeEvents.last { $0.title == "CPU 占用已回落" })
        XCTAssertTrue(ended.detail?.contains("本段的调用栈采样：\(output)") == true, ended.detail ?? "")

        // 下一段（仍在 10 分钟限频内）不得沿用上一段的采样。
        state.record(report(.ongoing), logLinesInWindow: 0)
        let next = try XCTUnwrap(state.runtimeEvents.last { $0.title == "CPU 占用持续偏高" })
        XCTAssertFalse(next.detail?.contains(output) == true, next.detail ?? "")
        XCTAssertEqual(recorder.recorded.count, 1)
    }

    /// 真机 2026-09-30、10-01 几次爆发只烧 2~3 分钟，等不到 10 分钟后的「持续偏高」报告，
    /// 一份调用栈都没留下。现在开段约 30 秒就采，回落时的总结写明文件在哪。
    func testShortBurstIsSampledEarlyAndTheEndedReportPointsToIt() async throws {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = SampleRunRecorder()
        state.cpuSampleRunner = recorder.run

        // 15 秒一采：4 次 40% 开段，再 3 次空闲回落，全程约 2 分钟，没有中途报告。
        let origin = Date().addingTimeInterval(-300)
        var cpu = 0.0
        func sample(_ index: Int) -> ProcessResourceSample {
            ProcessResourceSample(
                capturedAt: origin.addingTimeInterval(Double(index) * 15),
                userSeconds: cpu, systemSeconds: 0,
                residentBytes: 80 * 1_048_576, threadCount: 9, mainThreadSeconds: cpu * 0.9
            )
        }
        state.ingestCPUSample(sample(0), logLinesInWindow: 0)
        for index in 1...4 {
            cpu += 0.4 * 15
            state.ingestCPUSample(sample(index), logLinesInWindow: 0)
        }
        let task = try XCTUnwrap(state.cpuSampleTask, "开段 30 秒后必须已在采样")
        await task.value
        XCTAssertEqual(recorder.recorded.count, 1)
        XCTAssertFalse(state.runtimeEvents.contains { $0.title == "CPU 占用持续偏高" }, "短爆发不该有中途报告")

        for index in 5...7 {
            state.ingestCPUSample(sample(index), logLinesInWindow: 0)
        }
        let output = try XCTUnwrap(recorder.recorded.first?.last)
        let ended = try XCTUnwrap(state.runtimeEvents.last { $0.title == "CPU 占用已回落" })
        XCTAssertTrue(ended.detail?.contains("本段的调用栈采样：\(output)") == true, ended.detail ?? "")
        XCTAssertEqual(recorder.recorded.count, 1)
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
