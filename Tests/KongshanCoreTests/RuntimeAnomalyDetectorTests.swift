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

    /// 阈值形状决定了能看见什么。120 秒 3 次抓得住成簇爆发，却完全看不见
    /// 「每几小时卡一次、每次 10 秒」的慢性滴漏——真机 2026-09-01 正是后者：
    /// 18 小时里 17 次解析超时（用户累计白等约 170 秒），折合 0.94 次/小时，
    /// 连原本 1 小时 ≥8 次的慢性阈值都够不到，一条事件都没留。
    func testChronicDetectorCatchesDripThatBurstDetectorCannotSee() throws {
        var burst = DNSStallDetector()
        var chronic = DNSStallDetector.chronic()
        var burstReports: [DNSStallReport] = []
        var chronicReports: [DNSStallReport] = []

        // 每小时 1 次，共 6 次：任何 120 秒窗口里都只有 1 次，永远够不到爆发阈值；
        // 这正是真机观察到的密度（0.94 次/小时）。
        for index in 0..<6 {
            let at = origin.addingTimeInterval(Double(index) * 3_600)
            let line = directStallLine(destination: "shop.example.invalid:443")
            if let report = burst.ingest(line, at: at, physicalBytes: 0) { burstReports.append(report) }
            if let report = chronic.ingest(line, at: at, physicalBytes: 0) { chronicReports.append(report) }
        }
        let closeout = origin.addingTimeInterval(6 * 3_600 + 60)
        if let report = burst.flush(at: closeout, physicalBytes: 0) { burstReports.append(report) }
        if let report = chronic.flush(at: closeout, physicalBytes: 0) { chronicReports.append(report) }

        XCTAssertTrue(burstReports.isEmpty, "这种形状本就不该触发爆发检测")
        let chronicReport = try XCTUnwrap(chronicReports.first, "慢性检测必须报出来")
        XCTAssertEqual(chronicReport.kind, .chronic)
        XCTAssertEqual(chronicReport.totalStalls, 6)
    }

    /// 慢性检测不能把偶发的几次当成故障，否则消息页会被噪音淹掉，
    /// 存档一旦变噪音就和被清空没区别。
    func testChronicDetectorStaysQuietBelowItsThreshold() {
        var chronic = DNSStallDetector.chronic()
        for index in 0..<4 {
            _ = chronic.ingest(
                directStallLine(destination: "shop.example.invalid:443"),
                at: origin.addingTimeInterval(Double(index) * 3_600),
                physicalBytes: 0
            )
        }
        XCTAssertNil(chronic.flush(at: origin.addingTimeInterval(6 * 3_600 + 60), physicalBytes: 0))
    }

    /// 默认形状仍是爆发，既有接线与断言不受影响。
    func testDefaultDetectorReportsBurstKind() throws {
        var detector = DNSStallDetector(windowDuration: 60, minimumStalls: 1)
        _ = detector.ingest(
            directStallLine(destination: "shop.example.invalid:443"),
            at: origin,
            physicalBytes: 0
        )
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(61), physicalBytes: 0))
        XCTAssertEqual(report.kind, .burst)
    }

    /// 故障最严重的形态是「一开就全失败、用户几十秒内手动关掉」——窗口远没到期。
    /// 旧实现在内核停止时直接 `window = nil`，把证据整个丢掉。
    /// 真机 2026-09-02 22:41：节点 276 次建连全失败，52 秒后用户关掉代理，
    /// 消息页一条记录都没有。
    func testOutboundFinishSettlesWindowThatNeverReachedItsDeadline() throws {
        var detector = OutboundFailureDetector()
        for index in 0..<30 {
            _ = detector.ingest(
                failureLine(tag: "node-x", host: "api.example.invalid:443", reason: "failed to create session: EOF"),
                at: origin.addingTimeInterval(Double(index))
            )
        }
        // 窗口是 600 秒，这里只过了 30 秒——flush 按设计不该出报告。
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(30)))

        let report = try XCTUnwrap(
            detector.finish(at: origin.addingTimeInterval(30)),
            "内核停止时必须先结算，不能丢弃"
        )
        XCTAssertEqual(report.failures, 30)
        XCTAssertEqual(report.outboundTag, "node-x")
        XCTAssertNil(detector.finish(at: origin.addingTimeInterval(31)), "结算后窗口要清空")
    }

    /// 结算不等于放宽阈值：达不到门槛照样不报，否则每次停内核都会多出一条噪音。
    func testOutboundFinishStaysSilentBelowThreshold() {
        var detector = OutboundFailureDetector()
        for index in 0..<3 {
            _ = detector.ingest(
                failureLine(tag: "node-x", host: "api.example.invalid:443", reason: "failed to create session: EOF"),
                at: origin.addingTimeInterval(Double(index))
            )
        }
        XCTAssertNil(detector.finish(at: origin.addingTimeInterval(4)))
    }

    /// DNS 侧同理。
    func testDNSFinishSettlesUnexpiredWindow() throws {
        var detector = DNSStallDetector(windowDuration: 600, minimumStalls: 3)
        for index in 0..<4 {
            _ = detector.ingest(
                directStallLine(destination: "shop.example.invalid:443"),
                at: origin.addingTimeInterval(Double(index)),
                physicalBytes: 0
            )
        }
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(10), physicalBytes: 0))
        let report = try XCTUnwrap(detector.finish(at: origin.addingTimeInterval(10), physicalBytes: 0))
        XCTAssertEqual(report.totalStalls, 4)
        XCTAssertNil(detector.finish(at: origin.addingTimeInterval(11), physicalBytes: 0))
    }

    /// 直连也在大面积失败 ⇒ 问题在本机网络，不在节点。
    ///
    /// 真机 2026-09-03 07:32–07:51：机器睡着没网，连 `dial udp 223.5.5.5:53` 都
    /// `no route to internet`，3,216 行失败全被算到当时选中的节点头上，
    /// 报告还建议"换一个节点"——换了也没用，把用户引向了错误方向。
    func testDirectFailuresMarkTheProblemAsLocalNetwork() throws {
        var detector = OutboundFailureDetector()
        for index in 0..<25 {
            _ = detector.ingest(
                failureLine(tag: "node-x", host: "a.invalid",
                            reason: "failed to create session: dial tcp 203.0.113.5:443: no route to internet"),
                at: origin.addingTimeInterval(Double(index))
            )
            _ = detector.ingest(
                CoreLogLine.parse(
                    "[9\(index) 0ms] connection: open connection to dns.invalid:53 using "
                    + "outbound/direct[direct]: dial udp 203.0.113.1:53: no route to internet"
                ),
                at: origin.addingTimeInterval(Double(index))
            )
        }
        let report = try XCTUnwrap(detector.finish(at: origin.addingTimeInterval(30)))
        XCTAssertTrue(report.localNetworkLooksDown, "直连全挂时不能归咎于节点")
        XCTAssertEqual(report.directAttempts, 25)
        XCTAssertEqual(report.directFailures, 25)
    }

    /// 直连正常时仍然判为节点问题——这是原有行为，不能被上一条带跑。
    func testHealthyDirectKeepsTheBlameOnTheNode() throws {
        var detector = OutboundFailureDetector()
        for index in 0..<25 {
            _ = detector.ingest(
                failureLine(tag: "node-x", host: "a.invalid", reason: "failed to create session: EOF"),
                at: origin.addingTimeInterval(Double(index))
            )
            _ = detector.ingest(
                CoreLogLine.parse(
                    "[8\(index) 0ms] outbound/direct[direct]: outbound connection to b.invalid:443"
                ),
                at: origin.addingTimeInterval(Double(index))
            )
        }
        let report = try XCTUnwrap(detector.finish(at: origin.addingTimeInterval(30)))
        XCTAssertFalse(report.localNetworkLooksDown)
        XCTAssertEqual(report.directFailures, 0)
    }

    /// 直连样本太少时不下结论：宁可维持"节点问题"这个原有判断。
    func testTooFewDirectSamplesDoNotFlipTheVerdict() throws {
        var detector = OutboundFailureDetector()
        for index in 0..<25 {
            _ = detector.ingest(
                failureLine(tag: "node-x", host: "a.invalid", reason: "failed to create session: EOF"),
                at: origin.addingTimeInterval(Double(index))
            )
        }
        _ = detector.ingest(
            CoreLogLine.parse(
                "[70 0ms] connection: open connection to c.invalid:443 using "
                + "outbound/direct[direct]: dial tcp 203.0.113.2:443: no route to host"
            ),
            at: origin.addingTimeInterval(26)
        )
        let report = try XCTUnwrap(detector.finish(at: origin.addingTimeInterval(30)))
        XCTAssertFalse(report.localNetworkLooksDown, "1 次直连失败不足以推翻判断")
    }

    /// 真机 2026-09-03 断网期间 2,907 条直连失败一条都没被旧特征表认出来，
    /// 「直连也在挂」这个判据因此形同虚设。
    func testFailureMarkersRecognizeRealWorldNoRouteToInternet() {
        let line = CoreLogLine.parse(
            "[123 1ms] connection: open connection to 203.0.113.9:443 using "
            + "outbound/direct[direct]: dial tcp 203.0.113.9:443: no route to internet"
        )
        XCTAssertTrue(OutboundFailureDetector.isFailedAttempt(line))
        XCTAssertTrue(OutboundFailureDetector.isDirectOutbound(line))

        // 规则拒绝不算失败，否则开着广告拦截的用户天天收到误报。
        let rejected = CoreLogLine.parse(
            "[124 0ms] connection: open connection to ads.invalid:443 using "
            + "outbound/block[reject]: operation not permitted"
        )
        XCTAssertFalse(OutboundFailureDetector.isFailedAttempt(rejected))
    }

    /// 内核对 A/AAAA 并发失败写成 `(exchange6: … | exchange4: … no route to internet)`，
    /// 取尾段时右括号会跟着留下来，把同一原因劈成两类。
    /// 真机 2026-09-03 计数：`no route to internet` 2,849 次、带括号的 191 次。
    func testReasonDropsTrailingBracketLeftByParallelQueries() {
        let message = "open connection to a.invalid:443 using outbound/direct[direct]: "
            + "lookup a.invalid: (exchange6: dial udp 203.0.113.1:53: no route to internet"
            + " | exchange4: dial udp 203.0.113.1:53: no route to internet)"
        XCTAssertEqual(
            OutboundFailureDetector.normalizedReason(from: message),
            "no route to internet"
        )
        // 成对的括号不能被削掉，否则会把本来完整的尾段咬坏。
        XCTAssertEqual(OutboundFailureDetector.trimReasonPunctuation("(a | b)"), "(a | b)")
        XCTAssertEqual(OutboundFailureDetector.trimReasonPunctuation("connection refused"), "connection refused")
    }

    /// DNS 停摆统计同样要能在内核重启时清空，否则"重启前后各两次"会被并成一簇持续故障。
    func testDNSStallResetClearsWindow() {
        var detector = DNSStallDetector(windowDuration: 60, minimumStalls: 1)
        _ = detector.ingest(
            directStallLine(destination: "shop.example.invalid:443"),
            at: origin,
            physicalBytes: 0
        )
        detector.reset()
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(61), physicalBytes: 0))
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

    // MARK: - 出站失败率

    /// 每条连接一个 ID：检测器按连接 ID 去重，共用 ID 会被当成同一条连接。
    private var nextConnectionID = 100

    private func successLine(tag: String, host: String) -> CoreLogLine {
        nextConnectionID += 1
        return CoreLogLine.parse("[\(nextConnectionID) 2ms] outbound/anytls[\(tag)]: outbound connection to \(host):443")
    }

    private func failureLine(tag: String, host: String, reason: String = "failed to create session: dial tcp 203.0.113.9:8030: i/o timeout") -> CoreLogLine {
        nextConnectionID += 1
        return CoreLogLine.parse(
            "[\(nextConnectionID) 1.8s] connection: open connection to \(host):443 using outbound/anytls[\(tag)]: \(reason)"
        )
    }

    // MARK: - 按连接计数（真实日志的行序）

    /// 内核在**拨号开始时**就写 `outbound connection to`，失败的连接随后再写一行 ERROR
    /// （真机 2026-09-28 样本 388/388）。一条失败连接只算一次尝试、一次失败——
    /// 旧实现按行累加，算成两次尝试，失败率减半。
    func testFailedConnectionCountsOnceDespiteItsAttemptLine() throws {
        var detector = OutboundFailureDetector(
            windowDuration: 60, minimumAttempts: 5, minimumFailures: 5, minimumFailureRate: 0.1
        )
        for i in 0..<10 {
            let id = 5_000 + i
            _ = detector.ingest(
                CoreLogLine.parse("[\(id) 2ms] outbound/vless[node-x]: outbound connection to f\(i).example.invalid:443"),
                at: origin.addingTimeInterval(Double(i))
            )
            _ = detector.ingest(
                CoreLogLine.parse(
                    "[\(id) 5.0s] connection: open connection to f\(i).example.invalid:443 using "
                    + "outbound/vless[node-x]: dial tcp 203.0.113.9:443: i/o timeout"
                ),
                at: origin.addingTimeInterval(Double(i) + 0.5)
            )
        }
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(61)))
        XCTAssertEqual(report.attempts, 10)
        XCTAssertEqual(report.failures, 10)
        XCTAssertEqual(report.failureRate, 1.0, accuracy: 0.001)
    }

    /// vless 成功的连接会写**两行** `outbound connection to`（真机 577 条成功连接各两行），同样只算一次。
    func testVLESSSuccessWritingTwoLinesCountsOnce() throws {
        var detector = OutboundFailureDetector(
            windowDuration: 60, minimumAttempts: 10, minimumFailures: 3, minimumFailureRate: 0.1
        )
        for i in 0..<20 {
            let id = 6_000 + i
            _ = detector.ingest(
                CoreLogLine.parse("[\(id) 16ms] outbound/vless[node-v]: outbound connection to s\(i).example.invalid:443"),
                at: origin.addingTimeInterval(Double(i))
            )
            _ = detector.ingest(
                CoreLogLine.parse("[\(id) 303ms] outbound/vless[node-v]: outbound connection to s\(i).example.invalid:443"),
                at: origin.addingTimeInterval(Double(i) + 0.3)
            )
        }
        for i in 0..<5 {
            let id = 7_000 + i
            _ = detector.ingest(
                CoreLogLine.parse("[\(id) 2ms] outbound/vless[node-v]: outbound connection to f\(i).example.invalid:443"),
                at: origin.addingTimeInterval(Double(30 + i))
            )
            _ = detector.ingest(
                CoreLogLine.parse(
                    "[\(id) 2.1s] connection: open connection to f\(i).example.invalid:443 using "
                    + "outbound/vless[node-v]: dial tcp 203.0.113.9:443: connection refused"
                ),
                at: origin.addingTimeInterval(Double(30 + i) + 0.5)
            )
        }
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(61)))
        XCTAssertEqual(report.attempts, 25)
        XCTAssertEqual(report.failures, 5)
        XCTAssertEqual(report.failureRate, 0.2, accuracy: 0.001, "按行累加时只有 5/50 = 10%")
    }

    private func report(reason: String, directAttempts: Int, directFailures: Int) -> OutboundFailureReport {
        OutboundFailureReport(
            windowStart: origin, windowEnd: origin.addingTimeInterval(600), outboundTag: "node-x",
            failures: 30, attempts: 30, distinctReasonCount: 1, dominantReason: reason,
            directAttempts: directAttempts, directFailures: directFailures
        )
    }

    /// 真机 2026-09-29：只开系统代理、直连 0 次，节点 `network is unreachable` 却被当成节点问题。
    /// 这类原因出在本机协议栈，直连样本不足时应判为本机网络。
    func testLocalReasonWithoutDirectSamplesBlamesTheLocalNetwork() {
        for reason in ["network is unreachable", "no route to internet"] {
            let r = report(reason: reason, directAttempts: 0, directFailures: 0)
            XCTAssertTrue(r.localNetworkLooksDown, reason)
            XCTAssertTrue(r.failureReasonSaysLocalNetworkDown, reason)
            XCTAssertFalse(r.directSaysLocalNetworkDown, reason)
        }
    }

    /// 直连样本够且正常：某节点报本机不可达，多半是它的地址（如 IPv6）在当前网络走不通，仍算节点侧。
    func testLocalReasonWithHealthyDirectKeepsTheBlameOnTheNode() {
        let r = report(reason: "network is unreachable", directAttempts: 20, directFailures: 0)
        XCTAssertFalse(r.localNetworkLooksDown)
    }

    /// `no route to internet` 是整机级的（sing-box 找不到默认网卡），直连样本再多也是本机问题。
    /// 真机 2026-10-01 23:18：直连 214 次、失败 91 次，仍被写成「本机网络正常」。
    func testNoRouteToInternetIsMachineWideEvenWithEnoughDirectSamples() {
        let r = report(reason: "no route to internet", directAttempts: 214, directFailures: 91)
        XCTAssertTrue(r.localNetworkLooksDown)
    }

    func testDirectFailureRateTiers() {
        XCTAssertFalse(report(reason: "i/o timeout", directAttempts: 100, directFailures: 10).directSaysLocalNetworkUnstable)
        XCTAssertTrue(report(reason: "i/o timeout", directAttempts: 100, directFailures: 30).directSaysLocalNetworkUnstable)
        let down = report(reason: "i/o timeout", directAttempts: 100, directFailures: 60)
        XCTAssertFalse(down.directSaysLocalNetworkUnstable)
        XCTAssertTrue(down.localNetworkLooksDown)
        XCTAssertFalse(report(reason: "i/o timeout", directAttempts: 3, directFailures: 3).directSaysLocalNetworkUnstable,
                       "样本不足不下结论")
    }

    /// 慢性窗口跨几个小时，中途网卡重连会把计数清零；累加要跨过重置，不能报「不可用」。
    func testChronicWindowAccumulatesTrafficAcrossCounterReset() throws {
        var detector = DNSStallDetector(windowDuration: 600, minimumStalls: 3)
        let stall = { (i: Int) in
            CoreLogLine.parse(
                "[\(4_000 + i) 10.0s] connection: open connection to s\(i).example.invalid:443 using "
                + "outbound/direct[direct]: lookup s\(i).example.invalid: context deadline exceeded"
            )
        }
        _ = detector.ingest(stall(0), at: origin, physicalBytes: 1_000_000)
        _ = detector.flush(at: origin.addingTimeInterval(60), physicalBytes: 3_000_000)
        _ = detector.ingest(stall(1), at: origin.addingTimeInterval(120), physicalBytes: 500_000)   // 重置
        _ = detector.ingest(stall(2), at: origin.addingTimeInterval(180), physicalBytes: 2_500_000)
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(601), physicalBytes: 2_500_000))
        XCTAssertEqual(report.physicalBytesDelta, 4_000_000, "重置前 2 MB + 重置后 2 MB")
    }

    func testCPUDetectorExposesWhenTheAnomalyOpened() {
        var detector = CPUAnomalyDetector()
        XCTAssertNil(detector.openAnomalyStartedAt)
        var total = 0.0
        for i in 0...5 {
            total += 5   // 每 10 秒烧 5 秒 = 50%
            _ = detector.ingest(ProcessResourceSample(
                capturedAt: origin.addingTimeInterval(Double(i) * 10), userSeconds: total, systemSeconds: 0,
                residentBytes: 50_000_000, threadCount: 8
            ))
        }
        XCTAssertNotNil(detector.openAnomalyStartedAt)
    }

    func testOrdinaryReasonWithoutDirectSamplesStaysOnTheNode() {
        let r = report(reason: "i/o timeout", directAttempts: 0, directFailures: 0)
        XCTAssertFalse(r.localNetworkLooksDown)
        XCTAssertFalse(r.hasEnoughDirectSamples)
    }

    /// 真机 2026-09-26 11:53：断网还没恢复，直连真实失败约 93%，旧口径算成 48%（封顶 50%），
    /// 判为「本机网络正常」并建议换节点。按连接计数后必须判为本机网络问题。
    func testPartialOutageWithRealisticLinesBlamesTheLocalNetwork() throws {
        var detector = OutboundFailureDetector()
        var offset = 0.0
        func feed(_ text: String) {
            _ = detector.ingest(CoreLogLine.parse(text), at: origin.addingTimeInterval(offset))
            offset += 0.1
        }
        for i in 0..<9 {
            feed("[\(8_000 + i) 2ms] outbound/direct[direct]: outbound connection to d\(i).example.invalid:443")
        }
        for i in 0..<125 {
            let id = 8_100 + i
            feed("[\(id) 1ms] outbound/direct[direct]: outbound connection to e\(i).example.invalid:443")
            feed(
                "[\(id) 3ms] connection: open connection to e\(i).example.invalid:443 using "
                + "outbound/direct[direct]: dial tcp 203.0.113.7:443: no route to internet"
            )
        }
        for i in 0..<60 {
            let id = 9_000 + i
            feed("[\(id) 1ms] outbound/vless[node-x]: outbound connection to n\(i).example.invalid:443")
            feed(
                "[\(id) 2ms] connection: open connection to n\(i).example.invalid:443 using "
                + "outbound/vless[node-x]: dial tcp 203.0.113.9:443: no route to internet"
            )
        }
        let report = try XCTUnwrap(detector.finish(at: origin.addingTimeInterval(offset)))
        XCTAssertEqual(report.directAttempts, 134)
        XCTAssertEqual(report.directFailures, 125)
        XCTAssertEqual(report.attempts, 60)
        XCTAssertEqual(report.failures, 60)
        XCTAssertTrue(report.localNetworkLooksDown, "直连 93% 失败时问题在本机网络，不在节点")
    }

    func testOutboundFailureReportsWorstNodeWithRateAndReason() throws {
        var detector = OutboundFailureDetector(
            windowDuration: 60, minimumAttempts: 10, minimumFailures: 3, minimumFailureRate: 0.1
        )
        for i in 0..<20 {
            _ = detector.ingest(successLine(tag: "node-aaa", host: "s\(i).example.invalid"),
                                at: origin.addingTimeInterval(Double(i)))
        }
        for i in 0..<5 {
            _ = detector.ingest(failureLine(tag: "node-aaa", host: "f\(i).example.invalid"),
                                at: origin.addingTimeInterval(Double(20 + i)))
        }
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(61)))
        XCTAssertEqual(report.outboundTag, "node-aaa")
        XCTAssertEqual(report.failures, 5)
        XCTAssertEqual(report.attempts, 25)
        XCTAssertEqual(report.failureRate, 0.2, accuracy: 0.001)
        XCTAssertEqual(report.dominantReason, "i/o timeout")
    }

    /// 归因要落到真实日志的四种形态上，且**任何形态都不得残留地址**。
    func testNormalizedReasonMatchesRealWorldShapes() {
        let cases: [(String, String)] = [
            ("failed to create session: dial tcp 198.51.100.87:8030: connect: connection refused", "connection refused"),
            ("failed to create session: EOF", "EOF"),
            ("failed to create session: read tcp 192.168.2.7:5010->203.0.113.9:8030: read: connection reset by peer", "connection reset by peer"),
            ("failed to create session: dial tcp 198.51.100.89:18081: i/o timeout", "i/o timeout")
        ]
        for (tail, expected) in cases {
            let message = "connection: open connection to x.example.invalid:443 using outbound/anytls[node-aaa]: \(tail)"
            let reason = OutboundFailureDetector.normalizedReason(from: message)
            XCTAssertEqual(reason, expected, "原始：\(tail)")
            XCTAssertFalse(reason.contains("212.87"), "原因不得残留地址：\(reason)")
            XCTAssertFalse(reason.contains("8030"), "原因不得残留端口：\(reason)")
        }
    }

    /// `context canceled` 是配置重载时主动取消旧连接，不是节点故障。
    func testContextCanceledIsNotCountedAsFailure() {
        let line = CoreLogLine.parse(
            "[104 1ms] connection: open connection to x.example.invalid:443 using outbound/anytls[node-aaa]: failed to create session: context canceled"
        )
        XCTAssertFalse(OutboundFailureDetector.isFailedAttempt(line),
                       "重载取消不得算成节点故障，否则每改一次设置都会误报")
    }

    /// **不得把规则主动拒绝算成节点故障。** 广告拦截每命中一次就写一条
    /// `operation not permitted`，误报会让开着拦截的用户天天收到"节点故障"。
    func testRuleRejectionsAndDirectAreNeverCountedAsNodeFailures() {
        var detector = OutboundFailureDetector(
            windowDuration: 60, minimumAttempts: 1, minimumFailures: 1, minimumFailureRate: 0.0
        )
        let reject = CoreLogLine.parse(
            "[102 8ms] connection: open connection to ads.example.invalid:443 using outbound/block[reject]: operation not permitted"
        )
        let direct = CoreLogLine.parse(
            "[103 5.7s] connection: open connection to a.example.invalid:443 using outbound/direct[direct]: dial tcp 198.51.100.7:18081: i/o timeout"
        )
        for i in 0..<10 {
            _ = detector.ingest(reject, at: origin.addingTimeInterval(Double(i)))
            _ = detector.ingest(direct, at: origin.addingTimeInterval(Double(i)))
        }
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(61)),
                     "reject 与 direct 都不该产生节点故障报告")
        XCTAssertNil(OutboundFailureDetector.outboundTag(in: reject.message))
        XCTAssertNil(OutboundFailureDetector.outboundTag(in: direct.message))
    }

    /// 偶发失败不报：低于阈值时保持安静，否则消息页会被正常抖动刷满。
    func testOccasionalFailuresStayBelowThreshold() {
        var detector = OutboundFailureDetector(
            windowDuration: 60, minimumAttempts: 20, minimumFailures: 5, minimumFailureRate: 0.1
        )
        for i in 0..<60 {
            _ = detector.ingest(successLine(tag: "node-bbb", host: "s\(i).example.invalid"),
                                at: origin.addingTimeInterval(Double(i) * 0.5))
        }
        for i in 0..<2 {
            _ = detector.ingest(failureLine(tag: "node-bbb", host: "f\(i).example.invalid"),
                                at: origin.addingTimeInterval(Double(31 + i)))
        }
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(61)))
    }

    /// 报告里不得出现服务器地址：那是用户的机场/自建服务器。
    func testReportCarriesNoServerAddress() throws {
        var detector = OutboundFailureDetector(
            windowDuration: 1, minimumAttempts: 1, minimumFailures: 1, minimumFailureRate: 0.0
        )
        _ = detector.ingest(failureLine(tag: "node-ccc", host: "x.example.invalid"),
                            at: origin)
        let report = try XCTUnwrap(detector.flush(at: origin.addingTimeInterval(2)))
        var strings: [String] = []
        func collect(_ m: Mirror) {
            for c in m.children {
                if let t = c.value as? String { strings.append(t) }
                collect(Mirror(reflecting: c.value))
            }
        }
        collect(Mirror(reflecting: report))
        XCTAssertTrue(strings.allSatisfy { !$0.contains("203.0.113.9") && !$0.contains("8030") },
                      "报告不得包含服务器地址或端口：\(strings)")
    }

    /// 内核重启要清空统计，否则两代内核的数据会被混进同一个窗口。
    func testResetClearsAccumulatedWindow() {
        var detector = OutboundFailureDetector(
            windowDuration: 60, minimumAttempts: 1, minimumFailures: 1, minimumFailureRate: 0.0
        )
        _ = detector.ingest(failureLine(tag: "node-ddd", host: "x.example.invalid"), at: origin)
        detector.reset()
        XCTAssertNil(detector.flush(at: origin.addingTimeInterval(61)))
    }
}
