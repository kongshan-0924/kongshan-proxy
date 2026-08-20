import Foundation
import XCTest
@testable import KongshanCore

/// 本文件里的域名全部是编造的（`.invalid` 保留后缀 / 明显占位串）。
/// 真实节点域名与用户内网域名一律不得进测试与文档，见 HANDOFF「别改回去的设计点」第 9 条。
final class RuntimeAnomalyDetectorTests: XCTestCase {

    // MARK: - CPU

    private let origin = Date(timeIntervalSince1970: 1_760_000_000)

    /// 按给定的每秒 CPU 百分比生成连续采样。`userRatio` 控制 user/system 配比。
    private func samples(
        percents: [Double],
        interval: TimeInterval = 1,
        userRatio: Double = 0.9,
        mainThreadRatio: Double = 0,
        residentBytes: UInt64 = 100 * 1024 * 1024,
        threadCount: Int = 12
    ) -> [ProcessResourceSample] {
        var user = 0.0
        var system = 0.0
        var mainThread = 0.0
        var result: [ProcessResourceSample] = [
            ProcessResourceSample(
                capturedAt: origin,
                userSeconds: 0,
                systemSeconds: 0,
                residentBytes: residentBytes,
                threadCount: threadCount,
                mainThreadSeconds: 0
            )
        ]
        for (index, percent) in percents.enumerated() {
            let consumed = percent / 100 * interval
            user += consumed * userRatio
            system += consumed * (1 - userRatio)
            mainThread += consumed * mainThreadRatio
            result.append(ProcessResourceSample(
                capturedAt: origin.addingTimeInterval(interval * Double(index + 1)),
                userSeconds: user,
                systemSeconds: system,
                residentBytes: residentBytes,
                threadCount: threadCount,
                mainThreadSeconds: mainThread
            ))
        }
        return result
    }

    private func drain(
        _ detector: inout CPUAnomalyDetector,
        _ samples: [ProcessResourceSample]
    ) -> [CPUAnomalyReport] {
        samples.compactMap { detector.ingest($0) }
    }

    func testFirstSampleAloneNeverReports() {
        var detector = CPUAnomalyDetector()
        let only = ProcessResourceSample(
            capturedAt: origin, userSeconds: 0, systemSeconds: 0, residentBytes: 0, threadCount: 1
        )
        XCTAssertNil(detector.ingest(only))
    }

    /// 测速、配置重载都会打出短尖峰。少于 breachesToOpen 次不能开异常段，
    /// 否则消息页会被正常操作刷满，真正的异常反而淹没。
    func testBriefSpikeDoesNotOpenAnomaly() {
        var detector = CPUAnomalyDetector(policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 3))
        let reports = drain(&detector, samples(percents: [40, 45, 2, 1, 1]))
        XCTAssertTrue(reports.isEmpty)
    }

    func testSustainedBurstReportsOnRecoveryWithAttributionFields() {
        var detector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 3, recoveriesToClose: 2)
        )
        let reports = drain(&detector, samples(
            percents: [30, 30, 30, 60, 30, 1, 1],
            userRatio: 0.9
        ))
        let report = try? XCTUnwrap(reports.first)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(report?.phase, .ended)
        XCTAssertEqual(report?.peakPercent ?? 0, 60, accuracy: 0.001)
        // user 占比是归因第一判据：接近 1 表示纯计算，明显偏低表示 I/O 密集。
        XCTAssertEqual(report?.userShare ?? 0, 0.9, accuracy: 0.01)
        XCTAssertGreaterThan(report?.cpuSecondsConsumed ?? 0, 0)
    }

    /// 主线程占比是分辨「界面在烧」与「后台在烧」的判据。2026-08-18 那次进程累计
    /// 1070 分钟而主线程只有 8.5 秒，正是靠这个比值排除了 SwiftUI 渲染。
    func testMainThreadShareSeparatesUIBurnFromBackgroundBurn() {
        var uiDetector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 2, recoveriesToClose: 1)
        )
        let uiReports = drain(&uiDetector, samples(percents: [40, 40, 40, 1], mainThreadRatio: 0.95))
        XCTAssertGreaterThan(uiReports.first?.mainThreadShare ?? 0, 0.9)

        var backgroundDetector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 2, recoveriesToClose: 1)
        )
        let backgroundReports = drain(
            &backgroundDetector,
            samples(percents: [40, 40, 40, 1], mainThreadRatio: 0.01)
        )
        XCTAssertLessThan(backgroundReports.first?.mainThreadShare ?? 1, 0.1)
    }

    /// 异常段起点必须锚在真实采样点上，不能按固定秒数回推——
    /// 采样节律一改，回推法算出的起点和消耗都是错的。
    func testWindowStartAnchorsToRealSampleRegardlessOfInterval() {
        var detector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 3, recoveriesToClose: 1)
        )
        let reports = drain(&detector, samples(percents: [30, 30, 30, 1], interval: 5))
        let report = try? XCTUnwrap(reports.first)
        // 第一次突破发生在 origin→origin+5 之间，锚点应是 origin。
        XCTAssertEqual(report?.startedAt, origin)
    }

    /// **关键设计守卫**：一直烧到用户退出的异常，如果只在结束时才报告，会一条都不产出——
    /// 2026-08-18 那次 929 分钟累计 CPU 无法归因正是这个原因。
    func testOngoingBurstEmitsInterimReportBeforeItEnds() {
        var detector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(
                sustainedPercent: 12,
                breachesToOpen: 3,
                recoveriesToClose: 3,
                interimInterval: 10
            )
        )
        let reports = drain(&detector, samples(percents: Array(repeating: 40.0, count: 40)))
        XCTAssertFalse(reports.isEmpty, "持续异常必须在进行中就留下记录")
        XCTAssertTrue(reports.allSatisfy { $0.phase == .ongoing })
    }

    /// 中途报告必须指数退避：固定节律在 2026-08-20 的 8 小时爆发中产出 182 条告警，
    /// 占满 200 条事件环，把 DNS 与换网事件全部挤出。
    func testInterimReportsBackOffExponentially() {
        var detector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(
                sustainedPercent: 12,
                breachesToOpen: 2,
                recoveriesToClose: 3,
                interimInterval: 10,
                interimBackoff: 2,
                maxInterimInterval: 3600
            )
        )
        // 600 秒持续爆发，1 秒一采样。固定 10 秒节律会出 ~59 条；退避应只出 ~5 条。
        let reports = drain(&detector, samples(percents: Array(repeating: 40.0, count: 600)))
        XCTAssertFalse(reports.isEmpty, "长爆发必须有中途报告")
        XCTAssertLessThanOrEqual(reports.count, 6, "600 秒爆发按 10/20/40/80/160/320 退避，不该超过 6 条")
        XCTAssertTrue(reports.allSatisfy { $0.phase == .ongoing })
        // 每条都是累计口径：最后一条覆盖的窗口必须比第一条长。
        if let first = reports.first, let last = reports.last {
            XCTAssertGreaterThan(last.duration, first.duration)
        }
    }

    func testFinishFlushesStillOpenWindow() {
        var detector = CPUAnomalyDetector(
            policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 2, interimInterval: 3600)
        )
        _ = drain(&detector, samples(percents: [50, 50, 50]))
        let final = detector.finish(at: origin.addingTimeInterval(10))
        XCTAssertEqual(final?.phase, .ended)
    }

    /// 睡眠唤醒与时钟回拨会让相邻采样的间隔失真。间隔非正时必须整段跳过，
    /// 不能算出天文数字的百分比再据此报异常。
    func testNonMonotonicSamplesAreIgnored() {
        var detector = CPUAnomalyDetector(policy: CPUAnomalyPolicy(sustainedPercent: 12, breachesToOpen: 1))
        let first = ProcessResourceSample(
            capturedAt: origin, userSeconds: 10, systemSeconds: 1, residentBytes: 0, threadCount: 1
        )
        let rewound = ProcessResourceSample(
            capturedAt: origin.addingTimeInterval(-60),
            userSeconds: 20, systemSeconds: 2, residentBytes: 0, threadCount: 1
        )
        _ = detector.ingest(first)
        XCTAssertNil(detector.ingest(rewound))
    }

    // MARK: - 采样器资源纪律

    /// `task_threads` 返回的每条线程 send right 必须逐一归还。不还的话，同一线程的
    /// right 合并计数（urefs）每采样 +1——本测试用调用线程自己的端口做精确判据：
    /// 300 次采样后 urefs 只允许零星波动，线性增长即视为泄漏回归。
    /// （`pthread_mach_thread_np` 只读名字不取新引用，测试本身不干扰计数。）
    func testSamplerReturnsEveryThreadPortRight() {
        let selfPort = pthread_mach_thread_np(pthread_self())
        var before: mach_port_urefs_t = 0
        XCTAssertEqual(
            mach_port_get_refs(mach_task_self_, selfPort, MACH_PORT_RIGHT_SEND, &before),
            KERN_SUCCESS
        )

        for _ in 0..<300 {
            XCTAssertNotNil(ProcessResourceSampler.current())
        }

        var after: mach_port_urefs_t = 0
        XCTAssertEqual(
            mach_port_get_refs(mach_task_self_, selfPort, MACH_PORT_RIGHT_SEND, &after),
            KERN_SUCCESS
        )
        XCTAssertLessThanOrEqual(
            Int(after) - Int(before), 8,
            "300 次采样后本线程端口 send urefs 增长 \(Int(after) - Int(before))：任何线性增长都表示 task_threads 的线程 right 没有归还"
        )
    }

    // MARK: - DNS 停摆

    private func stallLine(destination: String, lookup: String) -> CoreLogLine {
        CoreLogLine.parse(
            "[123456 10.0s] connection: open connection to \(destination) using "
            + "outbound/anytls[node-placeholder]: failed to create session: "
            + "lookup \(lookup): (exchange4: context deadline exceeded | exchange6: context deadline exceeded)"
        )
    }

    private func directStallLine(destination: String) -> CoreLogLine {
        CoreLogLine.parse(
            "[123457 10.0s] connection: open connection to \(destination) using "
            + "outbound/direct[direct]: lookup \(DNSStallDetector.stripPort(destination)): "
            + "(exchange6: context deadline exceeded | exchange4: context deadline exceeded)"
        )
    }

    /// lookup 的名字与连接目标不同 ⇒ 内核在解析**出站自己的服务器域名**，
    /// 这类失败会让整条代理停摆。判据与协议措辞无关，加协议不会漏。
    func testOutboundServerDomainStallIsDistinguishedFromOrdinaryLookup() {
        let nodeStall = stallLine(destination: "api.example.invalid:443", lookup: "server.node-placeholder.invalid")
        let plainStall = directStallLine(destination: "shop.example.invalid:443")

        XCTAssertTrue(DNSStallDetector.isResolutionStall(nodeStall))
        XCTAssertTrue(DNSStallDetector.stallsOutboundServerDomain(nodeStall))
        XCTAssertTrue(DNSStallDetector.isResolutionStall(plainStall))
        XCTAssertFalse(DNSStallDetector.stallsOutboundServerDomain(plainStall))
    }

    func testWindowReportsCountsSplitByPathWithThroughputEvidence() {
        var detector = DNSStallDetector(windowDuration: 60, minimumStalls: 3)
        var report: DNSStallReport?
        for index in 0..<3 {
            report = detector.ingest(
                stallLine(destination: "api.example.invalid:443", lookup: "server.node-placeholder.invalid"),
                at: origin.addingTimeInterval(Double(index)),
                physicalBytes: 1_000
            )
        }
        _ = detector.ingest(
            directStallLine(destination: "shop.example.invalid:443"),
            at: origin.addingTimeInterval(4),
            physicalBytes: 1_000
        )
        XCTAssertNil(report, "窗口未到期不出报告")

        let flushed = detector.flush(at: origin.addingTimeInterval(61), physicalBytes: 9_000)
        let final = try? XCTUnwrap(flushed)
        XCTAssertEqual(final?.outboundServerDomainStalls, 3)
        XCTAssertEqual(final?.generalStalls, 1)
        XCTAssertEqual(final?.distinctTargetCount, 2)
        // 网卡仍在收发 ⇒ 机器联网正常，问题落在被查询的解析器上，而不是链路整体中断。
        XCTAssertEqual(final?.physicalBytesDelta, 8_000)
    }

    /// 静默很久之后的新一次超时必须开新窗口，不能折进早已过期的旧窗口——
    /// 否则旧报告里会凭空多出一次几百秒后才发生的失败，时间范围也跟着错。
    func testStallAfterLongSilenceStartsFreshWindow() throws {
        var detector = DNSStallDetector(windowDuration: 60, minimumStalls: 2)
        for index in 0..<3 {
            _ = detector.ingest(
                directStallLine(destination: "shop.example.invalid:443"),
                at: origin.addingTimeInterval(Double(index)),
                physicalBytes: 0
            )
        }
        let report = try XCTUnwrap(detector.ingest(
            directStallLine(destination: "shop.example.invalid:443"),
            at: origin.addingTimeInterval(500),
            physicalBytes: 0
        ))
        XCTAssertEqual(report.generalStalls, 3, "迟到 500 秒的那次不属于旧窗口")
        XCTAssertEqual(report.windowEnd, origin.addingTimeInterval(2))
    }

    func testBelowMinimumStallsProducesNoReport() {
        var detector = DNSStallDetector(windowDuration: 60, minimumStalls: 3)
        _ = detector.ingest(
            directStallLine(destination: "shop.example.invalid:443"),
            at: origin,
            physicalBytes: 0
        )
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(61), physicalBytes: 10))
    }

    /// **隐私守卫**：报告里不得出现任何被解析的域名。目标里可能有用户的节点域名与内网域名。
    func testReportCarriesNoResolvedDomainAnywhere() throws {
        var detector = DNSStallDetector(windowDuration: 1, minimumStalls: 1)
        let secret = "server.node-placeholder.invalid"
        _ = detector.ingest(
            stallLine(destination: "api.example.invalid:443", lookup: secret),
            at: origin,
            physicalBytes: 0
        )
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(2), physicalBytes: 0))

        var strings: [String] = []
        func collect(_ mirror: Mirror) {
            for child in mirror.children {
                if let text = child.value as? String { strings.append(text) }
                collect(Mirror(reflecting: child.value))
            }
        }
        collect(Mirror(reflecting: report))
        XCTAssertTrue(
            strings.allSatisfy { !$0.localizedCaseInsensitiveContains("placeholder") && !$0.contains(".invalid") },
            "解析目标不得出现在报告的任何字段里，实际字符串：\(strings)"
        )
    }
}
