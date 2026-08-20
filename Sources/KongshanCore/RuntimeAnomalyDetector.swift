import Foundation

// MARK: - CPU 异常

public struct CPUAnomalyPolicy: Equatable, Sendable {
    /// 单次采样达到多少百分比算“高”。
    public var sustainedPercent: Double
    /// 连续多少次高才开一段异常（滤掉测速、配置重载这类正常尖峰）。
    public var breachesToOpen: Int
    /// 连续多少次回落才收一段。
    public var recoveriesToClose: Int
    /// 首次中途报告的等待时长。
    public var interimInterval: TimeInterval
    /// 每报一次中途报告，下一次的等待翻这个倍数。
    ///
    /// 固定节律在真机上已经翻过车：2026-08-20 一段 8 小时的爆发按 10 分钟一条产出了
    /// 182 条告警，占满 200 条事件环，把 DNS 停摆与换网事件全部挤出。指数退避下同样
    /// 8 小时只产出 5~6 条，信息量不减（每条都带完整累计数据），环里留得住别的事件。
    public var interimBackoff: Double
    /// 退避的上限，避免超长爆发彻底沉默。
    public var maxInterimInterval: TimeInterval

    public init(
        sustainedPercent: Double = 12,
        breachesToOpen: Int = 3,
        recoveriesToClose: Int = 3,
        interimInterval: TimeInterval = 600,
        interimBackoff: Double = 2,
        maxInterimInterval: TimeInterval = 3600 * 2
    ) {
        self.sustainedPercent = sustainedPercent
        self.breachesToOpen = breachesToOpen
        self.recoveriesToClose = recoveriesToClose
        self.interimInterval = interimInterval
        self.interimBackoff = interimBackoff
        self.maxInterimInterval = maxInterimInterval
    }

    public static let `default` = CPUAnomalyPolicy()
}

public struct CPUAnomalyReport: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// 异常仍在持续。**必须有这个相位**：2026-08-18 那次 929 分钟累计 CPU 之所以
        /// 无法归因，就是因为没有任何东西在异常“进行中”时留下记录；只在结束时才报告的
        /// 检测器，遇到一直烧到用户退出应用的那种异常会一条都不产出。
        case ongoing
        case ended
    }

    public let phase: Phase
    public let startedAt: Date
    public let observedUntil: Date
    public let averagePercent: Double
    public let peakPercent: Double
    /// user 占 user+system 的比例。接近 1 表示纯计算，明显偏低表示 I/O / 系统调用密集。
    public let userShare: Double
    public let cpuSecondsConsumed: Double
    public let peakResidentBytes: UInt64
    public let peakThreadCount: Int
    /// 本段内主线程消耗占进程总消耗的比例。接近 1 表示界面渲染在烧，接近 0 表示后台并发线程在烧。
    public let mainThreadShare: Double

    public var duration: TimeInterval { observedUntil.timeIntervalSince(startedAt) }
}

/// 把连续的资源采样折叠成“异常时段”。纯逻辑，不碰系统调用，便于单测。
public struct CPUAnomalyDetector: Sendable {
    private struct Window {
        var startedAt: Date
        var lastReportedAt: Date
        var nextInterimGap: TimeInterval
        var startUser: Double
        var startSystem: Double
        var startMainThread: Double
        var peakPercent: Double
        var peakResidentBytes: UInt64
        var peakThreadCount: Int
        var latest: ProcessResourceSample
    }

    private let policy: CPUAnomalyPolicy
    private var previous: ProcessResourceSample?
    /// 当前突破连击**开始之前**的那次采样。开段时以它为起点，异常段才不会漏掉最先
    /// 超阈值的那几次；用固定秒数回推会隐含「采样间隔恒为 1 秒」的假设，改节律就算错。
    private var streakAnchor: ProcessResourceSample?
    private var breachStreak = 0
    private var recoveryStreak = 0
    private var window: Window?

    public init(policy: CPUAnomalyPolicy = .default) {
        self.policy = policy
    }

    /// 喂入一次采样，必要时返回一条待记录的报告。
    public mutating func ingest(_ sample: ProcessResourceSample) -> CPUAnomalyReport? {
        defer { previous = sample }
        guard let previous else { return nil }

        let interval = sample.capturedAt.timeIntervalSince(previous.capturedAt)
        // 时钟回拨、睡眠唤醒后的异常间隔一律跳过，不能让它算出天文数字的百分比。
        guard interval > 0.5 else { return nil }

        let consumed = sample.totalSeconds - previous.totalSeconds
        guard consumed >= 0 else { return nil }
        let percent = consumed / interval * 100

        if percent >= policy.sustainedPercent {
            recoveryStreak = 0
            if breachStreak == 0 { streakAnchor = previous }
            breachStreak += 1
            if window != nil {
                updateWindow(with: sample, percent: percent)
                return interimReport(at: sample.capturedAt)
            }
            if breachStreak >= policy.breachesToOpen {
                openWindow(from: streakAnchor ?? previous, latest: sample, percent: percent)
            }
            return nil
        }

        breachStreak = 0
        streakAnchor = nil
        guard window != nil else { return nil }
        updateWindow(with: sample, percent: percent)
        recoveryStreak += 1
        guard recoveryStreak >= policy.recoveriesToClose else { return nil }
        return closeWindow(at: sample.capturedAt)
    }

    /// 应用要退出或停止采样时调用：把仍开着的异常段落盘，否则这段观测直接丢失。
    public mutating func finish(at date: Date) -> CPUAnomalyReport? {
        guard window != nil else { return nil }
        return closeWindow(at: date)
    }

    private mutating func openWindow(
        from anchor: ProcessResourceSample,
        latest sample: ProcessResourceSample,
        percent: Double
    ) {
        window = Window(
            startedAt: anchor.capturedAt,
            lastReportedAt: sample.capturedAt,
            nextInterimGap: policy.interimInterval,
            startUser: anchor.userSeconds,
            startSystem: anchor.systemSeconds,
            startMainThread: anchor.mainThreadSeconds,
            peakPercent: percent,
            peakResidentBytes: sample.residentBytes,
            peakThreadCount: sample.threadCount,
            latest: sample
        )
        recoveryStreak = 0
    }

    private mutating func updateWindow(with sample: ProcessResourceSample, percent: Double) {
        guard var current = window else { return }
        current.peakPercent = max(current.peakPercent, percent)
        current.peakResidentBytes = max(current.peakResidentBytes, sample.residentBytes)
        current.peakThreadCount = max(current.peakThreadCount, sample.threadCount)
        current.latest = sample
        window = current
    }

    private mutating func interimReport(at date: Date) -> CPUAnomalyReport? {
        guard var current = window,
              date.timeIntervalSince(current.lastReportedAt) >= current.nextInterimGap else { return nil }
        current.lastReportedAt = date
        current.nextInterimGap = min(current.nextInterimGap * policy.interimBackoff, policy.maxInterimInterval)
        window = current
        return report(from: current, phase: .ongoing, until: date)
    }

    private mutating func closeWindow(at date: Date) -> CPUAnomalyReport? {
        guard let current = window else { return nil }
        window = nil
        recoveryStreak = 0
        breachStreak = 0
        streakAnchor = nil
        return report(from: current, phase: .ended, until: date)
    }

    private func report(from window: Window, phase: CPUAnomalyReport.Phase, until: Date) -> CPUAnomalyReport {
        let user = window.latest.userSeconds - window.startUser
        let system = window.latest.systemSeconds - window.startSystem
        let consumed = user + system
        let mainThread = max(window.latest.mainThreadSeconds - window.startMainThread, 0)
        let duration = max(until.timeIntervalSince(window.startedAt), 0.001)
        return CPUAnomalyReport(
            phase: phase,
            startedAt: window.startedAt,
            observedUntil: until,
            averagePercent: consumed / duration * 100,
            peakPercent: window.peakPercent,
            userShare: consumed > 0 ? user / consumed : 0,
            cpuSecondsConsumed: consumed,
            peakResidentBytes: window.peakResidentBytes,
            peakThreadCount: window.peakThreadCount,
            mainThreadShare: consumed > 0 ? min(mainThread / consumed, 1) : 0
        )
    }
}

// MARK: - DNS 停摆

public struct DNSStallReport: Equatable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    /// 出站节点**自身域名**解析超时的次数。这类失败会让整条代理停摆，不只是某个网站打不开。
    public let outboundServerDomainStalls: Int
    /// 普通目标域名解析超时的次数。
    public let generalStalls: Int
    /// 涉及多少个不同的解析目标。**只记数量不记域名**——目标里可能有用户的内网域名与
    /// 节点域名，两者都属于绝不落盘的信息（见 HANDOFF「别改回去的设计点」第 9 条）。
    public let distinctTargetCount: Int
    /// 窗口内物理网卡收发字节增量。
    ///
    /// 这是区分「上游那台 DNS 出问题」与「整机网络断了」的判据，也是本轮诊断里缺掉的那一环：
    /// 若这段时间网卡仍在正常收发，说明机器联网正常，问题就落在被查询的那台解析器身上；
    /// 若增量接近 0，则是链路整体中断，换解析器没有意义。
    public let physicalBytesDelta: UInt64?

    public var totalStalls: Int { outboundServerDomainStalls + generalStalls }
}

/// 把内核日志里的解析超时按时间窗聚合。纯逻辑，日志行由调用方喂进来。
public struct DNSStallDetector: Sendable {
    private struct Window {
        var startedAt: Date
        var lastAt: Date
        var startBytes: UInt64?
        var outboundServerDomain = 0
        var general = 0
        var targets: Set<String> = []
    }

    private let windowDuration: TimeInterval
    private let minimumStalls: Int
    private var window: Window?

    public init(windowDuration: TimeInterval = 120, minimumStalls: Int = 3) {
        self.windowDuration = windowDuration
        self.minimumStalls = minimumStalls
    }

    /// 解析超时的指纹。内核对 A/AAAA 并发查询，超时会写成
    /// `(exchange6: context deadline exceeded | exchange4: context deadline exceeded)`。
    public static func isResolutionStall(_ line: CoreLogLine) -> Bool {
        line.message.lowercased().contains("context deadline exceeded")
    }

    /// 判断这次超时卡的是不是**出站节点自己的域名**。
    ///
    /// 不按协议名或 “failed to create session” 之类的措辞判断——那是 anytls 的话术，
    /// trojan/vless/hysteria2 各不相同，加一个协议就漏一类。改用与协议无关的结构判据：
    /// 被 lookup 的名字**不等于**这条连接的目标主机时，内核解析的就是出站自己的服务器域名。
    public static func stallsOutboundServerDomain(_ line: CoreLogLine) -> Bool {
        guard let lookup = lookupTarget(in: line.message) else { return false }
        guard let destination = line.host.map(stripPort) else { return false }
        return lookup.caseInsensitiveCompare(destination) != .orderedSame
    }

    static func lookupTarget(in message: String) -> String? {
        guard let range = message.range(of: "lookup ") else { return nil }
        let tail = message[range.upperBound...]
        let token = tail.prefix { !$0.isWhitespace }
        var target = String(token)
        while let last = target.last, last == ":" || last == "," { target.removeLast() }
        return target.isEmpty ? nil : target
    }

    static func stripPort(_ host: String) -> String {
        guard let separator = host.lastIndex(of: ":") else { return host }
        let port = host[host.index(after: separator)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return host }
        return String(host[..<separator])
    }

    public mutating func ingest(
        _ line: CoreLogLine,
        at date: Date,
        physicalBytes: UInt64?
    ) -> DNSStallReport? {
        guard Self.isResolutionStall(line) else { return flush(at: date, physicalBytes: physicalBytes) }

        // 先收掉已到期的窗口再开新的。否则长时间静默后的一次新超时会被折进旧窗口，
        // 报告的时间范围与计数都失真——旧窗口凭空多出一次几百秒后才发生的失败。
        let expired = flush(at: date, physicalBytes: physicalBytes)

        var current = window ?? Window(startedAt: date, lastAt: date, startBytes: physicalBytes)
        if Self.stallsOutboundServerDomain(line) {
            current.outboundServerDomain += 1
        } else {
            current.general += 1
        }
        if let target = Self.lookupTarget(in: line.message) {
            current.targets.insert(target.lowercased())
        }
        current.lastAt = date
        window = current
        return expired
    }

    /// 窗口到期就出报告。没有新日志行时也要由调用方周期性调用，否则最后一段永远不落盘。
    public mutating func flush(at date: Date, physicalBytes: UInt64?) -> DNSStallReport? {
        guard let current = window,
              date.timeIntervalSince(current.startedAt) >= windowDuration else { return nil }
        window = nil
        guard current.outboundServerDomain + current.general >= minimumStalls else { return nil }

        var delta: UInt64?
        if let start = current.startBytes, let end = physicalBytes, end >= start {
            delta = end - start
        }
        return DNSStallReport(
            windowStart: current.startedAt,
            windowEnd: current.lastAt,
            outboundServerDomainStalls: current.outboundServerDomain,
            generalStalls: current.general,
            distinctTargetCount: current.targets.count,
            physicalBytesDelta: delta
        )
    }
}
