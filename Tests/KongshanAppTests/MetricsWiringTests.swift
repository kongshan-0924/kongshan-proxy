import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 指标流水的接线回归。
@MainActor
final class MetricsWiringTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-mwire-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(root: URL, journal: MetricsJournal) -> AppState {
        AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            metricsJournal: journal,
            automaticallyInitialize: false
        )
    }

    private func sample(_ offset: Double, cpuSeconds: Double, mainSeconds: Double = 0) -> ProcessResourceSample {
        ProcessResourceSample(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            userSeconds: cpuSeconds * 0.97,
            systemSeconds: cpuSeconds * 0.03,
            residentBytes: 110 * 1_048_576,
            threadCount: 8,
            mainThreadSeconds: mainSeconds
        )
    }

    /// 不到一分钟不落盘；跨过一分钟落一行，且**算出的是这一分钟的平均**，
    /// 不是进程生涯累计——后者正是此前只能靠 `ps` 手算的那个数。
    func testEmitsOneLinePerMinuteWithWindowAverages() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root)
        let state = makeState(root: root, journal: journal)
        state.noteVisiblePage("连接")

        state.accumulateMetrics(sample(0, cpuSeconds: 100), physicalBytes: 0)
        state.accumulateMetrics(sample(30, cpuSeconds: 101.5), physicalBytes: 1_048_576)
        XCTAssertTrue(journal.samples().isEmpty, "不到一分钟不该落盘")

        // 60 秒里共消耗 3.6 秒 CPU ⇒ 6%，正是"低于 12% 阈值却持续存在"的那一档。
        state.accumulateMetrics(sample(60, cpuSeconds: 103.6), physicalBytes: 3 * 1_048_576)

        let samples = journal.samples()
        XCTAssertEqual(samples.count, 1)
        let first = try? XCTUnwrap(samples.first)
        XCTAssertEqual(first?.cpu ?? 0, 6.0, accuracy: 0.05)
        XCTAssertEqual(first?.win ?? 0, 60, accuracy: 0.1)
        XCTAssertEqual(first?.page, "连接", "归因要靠它：只知道『主线程在渲染』定位不到页面")
        XCTAssertEqual(first?.net ?? 0, 3.0, accuracy: 0.01)
        XCTAssertEqual(first?.th, 8)
    }

    /// 峰值取自窗口内的单次采样，不能被平均值抹平——
    /// 「均值 6% 但峰值 80%」和「一直 6%」是完全不同的两回事。
    func testPeakSurvivesAveraging() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root)
        let state = makeState(root: root, journal: journal)

        state.accumulateMetrics(sample(0, cpuSeconds: 0), physicalBytes: nil)
        state.accumulateMetrics(sample(15, cpuSeconds: 0.1), physicalBytes: nil)
        // 这一拍 15 秒里烧掉 12 秒 ⇒ 80%
        state.accumulateMetrics(sample(30, cpuSeconds: 12.1), physicalBytes: nil)
        state.accumulateMetrics(sample(60, cpuSeconds: 12.2), physicalBytes: nil)

        let first = try? XCTUnwrap(journal.samples().first)
        XCTAssertEqual(first?.peak ?? 0, 80.0, accuracy: 1.0)
        XCTAssertLessThan(first?.cpu ?? 99, 25, "均值不该被峰值带跑")
    }

    /// 落盘后必须清零，否则计数会跨窗口累加，越到后面越离谱。
    func testCountersResetBetweenWindows() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root)
        let state = makeState(root: root, journal: journal)

        state.accumulateMetrics(sample(0, cpuSeconds: 0), physicalBytes: 0)
        state.accumulateMetrics(sample(60, cpuSeconds: 6), physicalBytes: 1_048_576)
        state.accumulateMetrics(sample(120, cpuSeconds: 6.6), physicalBytes: 2 * 1_048_576)

        let samples = journal.samples()
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].cpu, 10.0, accuracy: 0.1)
        XCTAssertEqual(samples[1].cpu, 1.0, accuracy: 0.1, "第二段只算它自己的 0.6 秒")
        XCTAssertEqual(samples[1].net, 1.0, accuracy: 0.01, "网卡增量同样要按段算")
    }

    /// 睡眠唤醒后跨度会远大于 60 秒。**如实记下来**——那本身就是线索，
    /// 不能悄悄按名义值算成 60 秒，否则 CPU 百分比会被放大好几倍。
    func testLongGapIsRecordedAsIs() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = MetricsJournal(directory: root)
        let state = makeState(root: root, journal: journal)

        state.accumulateMetrics(sample(0, cpuSeconds: 0), physicalBytes: nil)
        state.accumulateMetrics(sample(3_600, cpuSeconds: 36), physicalBytes: nil)

        let first = try? XCTUnwrap(journal.samples().first)
        XCTAssertEqual(first?.win ?? 0, 3_600, accuracy: 1)
        XCTAssertEqual(first?.cpu ?? 0, 1.0, accuracy: 0.05, "按真实跨度算，不是按名义 60 秒")
    }

    private func outboundReport(directAttempts: Int, directFailures: Int) -> OutboundFailureReport {
        OutboundFailureReport(
            windowStart: Date(timeIntervalSince1970: 1_700_000_000),
            windowEnd: Date(timeIntervalSince1970: 1_700_000_540),
            outboundTag: "node-placeholder",
            failures: 145,
            attempts: 383,
            distinctReasonCount: 1,
            dominantReason: "no route to internet",
            directAttempts: directAttempts,
            directFailures: directFailures
        )
    }

    /// 直连也在挂时**不能建议换节点**——真机 2026-09-03 就是这样把用户引向错误方向的。
    func testLocalNetworkOutageDoesNotBlameTheNode() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root, journal: MetricsJournal(directory: root))

        state.record(outboundReport(directAttempts: 25, directFailures: 25))

        let event = state.runtimeEvents.last
        XCTAssertEqual(event?.title, "本机网络不通，期间建连大量失败")
        XCTAssertTrue(event?.detail?.contains("换节点无用") == true, "实际：\(event?.detail ?? "nil")")
        XCTAssertFalse(event?.detail?.contains("换一个节点") == true)
    }

    /// 直连正常时仍按节点问题处理，建议照给——不能被上一条带跑。
    func testHealthyDirectStillBlamesTheNode() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root, journal: MetricsJournal(directory: root))

        state.record(outboundReport(directAttempts: 40, directFailures: 0))

        let event = state.runtimeEvents.last
        XCTAssertEqual(event?.title, "节点建连失败偏多")
        XCTAssertTrue(event?.detail?.contains("换一个节点") == true)
        XCTAssertTrue(event?.detail?.contains("本机网络正常") == true)
    }

    /// 跨度不足 1 分钟要写秒。`%.0f 分钟` 会把 20 秒说成「0 分钟内」，
    /// 真机 2026-09-03 07:20 就留下过这种读不懂的记录。
    func testSubMinuteSpanIsRenderedInSeconds() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(AppState.spanText(from: start, to: start.addingTimeInterval(20)), "20 秒")
        XCTAssertEqual(AppState.spanText(from: start, to: start.addingTimeInterval(59)), "59 秒")
        XCTAssertEqual(AppState.spanText(from: start, to: start.addingTimeInterval(600)), "10 分钟")
        // 零跨度也不能写成 0，否则同样读不懂。
        XCTAssertEqual(AppState.spanText(from: start, to: start), "1 秒")
    }

    /// 局域网共享默认关闭。打开等于让同网段任何设备都能用你的出口，
    /// 升级绝不能凭空把它打开。
    func testLANSharingDefaultsOff() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root, journal: MetricsJournal(directory: root))
        XCTAssertFalse(state.lanSharingEnabled)
        // 中转层没在跑时不该给出地址——那会让用户去填一个连不上的端口。
        XCTAssertNil(state.currentRelayPort)
    }

    /// 开关要落盘，并在消息页留痕：这是个影响安全边界的状态，
    /// 事后必须能回答"什么时候开的"。
    func testTogglingLANSharingPersistsAndRecordsEvent() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root, journal: MetricsJournal(directory: root))

        await state.setLANSharing(enabled: true)
        XCTAssertTrue(state.lanSharingEnabled)
        XCTAssertEqual(state.runtimeEvents.last?.title, "已开启局域网共享")

        await state.setLANSharing(enabled: false)
        XCTAssertFalse(state.lanSharingEnabled)
        XCTAssertEqual(state.runtimeEvents.last?.title, "已关闭局域网共享")
    }
}
