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

    public init(
        phase: Phase,
        startedAt: Date,
        observedUntil: Date,
        averagePercent: Double,
        peakPercent: Double,
        userShare: Double,
        cpuSecondsConsumed: Double,
        peakResidentBytes: UInt64,
        peakThreadCount: Int,
        mainThreadShare: Double
    ) {
        self.phase = phase
        self.startedAt = startedAt
        self.observedUntil = observedUntil
        self.averagePercent = averagePercent
        self.peakPercent = peakPercent
        self.userShare = userShare
        self.cpuSecondsConsumed = cpuSecondsConsumed
        self.peakResidentBytes = peakResidentBytes
        self.peakThreadCount = peakThreadCount
        self.mainThreadShare = mainThreadShare
    }

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

/// 同一种故障的两种形状。分开是因为**阈值形状决定了能看见什么**：
/// 120 秒 3 次能抓住成簇爆发，却完全看不见「每几分钟卡一次、每次 10 秒」的慢性滴漏——
/// 真机 2026-08-26 就是后者：2 小时 44 分内 30 次解析超时，`.burst` 一条事件都没留。
public enum DNSStallKind: String, Equatable, Sendable {
    /// 短窗口成簇爆发：解析器刚出问题或链路刚断。
    case burst
    /// 长窗口零星累积：解析器长期不稳，用户每次卡 10 秒但从不成簇。
    case chronic
}

public struct DNSStallReport: Equatable, Sendable {
    public let kind: DNSStallKind
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

    private let kind: DNSStallKind
    private let windowDuration: TimeInterval
    private let minimumStalls: Int
    private var window: Window?

    public init(
        kind: DNSStallKind = .burst,
        windowDuration: TimeInterval = 120,
        minimumStalls: Int = 3
    ) {
        self.kind = kind
        self.windowDuration = windowDuration
        self.minimumStalls = minimumStalls
    }

    /// 慢性滴漏用的参数：6 小时内累计 5 次即报。
    ///
    /// 原本取 1 小时 ≥8 次，真机 2026-09-01 证明这个形状仍然太粗：18 小时里 17 次超时、
    /// 每次都卡满 10 秒（用户累计白等约 170 秒），可折算下来只有 0.94 次/小时，
    /// 一次都报不出来。窗口拉长到 6 小时后，同样的滴漏会稳定报出来，
    /// 而正常网络在 6 小时里凑不满 5 次。
    public static func chronic() -> DNSStallDetector {
        DNSStallDetector(kind: .chronic, windowDuration: 6 * 3600, minimumStalls: 5)
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

    /// 不结算地清空。仅用于确实不该出报告的场景；内核停止请用 `finish`——
    /// 直接丢弃未到期的窗口，等于在故障最严重时销毁唯一的证据。
    public mutating func reset() {
        window = nil
    }

    /// 内核停止/重启时**先结算再清空**。达不到阈值仍返回 nil，不会因为"停止"就凭空多报。
    public mutating func finish(at date: Date, physicalBytes: UInt64?) -> DNSStallReport? {
        guard let current = window else { return nil }
        return settle(current, physicalBytes: physicalBytes)
    }

    /// 窗口到期就出报告。没有新日志行时也要由调用方周期性调用，否则最后一段永远不落盘。
    public mutating func flush(at date: Date, physicalBytes: UInt64?) -> DNSStallReport? {
        guard let current = window,
              date.timeIntervalSince(current.startedAt) >= windowDuration else { return nil }
        return settle(current, physicalBytes: physicalBytes)
    }

    private mutating func settle(_ current: Window, physicalBytes: UInt64?) -> DNSStallReport? {
        window = nil
        guard current.outboundServerDomain + current.general >= minimumStalls else { return nil }

        var delta: UInt64?
        if let start = current.startBytes, let end = physicalBytes, end >= start {
            delta = end - start
        }
        return DNSStallReport(
            kind: kind,
            windowStart: current.startedAt,
            windowEnd: current.lastAt,
            outboundServerDomainStalls: current.outboundServerDomain,
            generalStalls: current.general,
            distinctTargetCount: current.targets.count,
            physicalBytesDelta: delta
        )
    }
}

// MARK: - 出站失败率

public struct OutboundFailureReport: Equatable, Sendable {
    public let windowStart: Date
    public let windowEnd: Date
    /// 出站 tag（`node-<uuid>`）。调用方负责翻成用户看得懂的节点名再展示。
    public let outboundTag: String
    public let failures: Int
    public let attempts: Int
    /// 失败原因的去重条数。同一原因反复出现说明是稳定故障，多种原因混杂更像链路整体不稳。
    public let distinctReasonCount: Int
    /// 出现次数最多的失败原因（已去掉地址与端口）。
    public let dominantReason: String

    public var failureRate: Double {
        attempts > 0 ? Double(failures) / Double(attempts) : 0
    }
}

/// 按出站 tag 聚合会话建立失败。纯逻辑，日志行由调用方喂入。
///
/// 存在的理由：节点间歇性故障此前只能靠翻内核日志发现。真机 2026-08-22~23 的样本里，
/// 当前主节点 8,198 次尝试失败 476 次（5.8%），且呈簇状（单小时 251 次），
/// 用户侧表现为"时好时坏"，但界面上没有任何地方说得出是节点在掉。
public struct OutboundFailureDetector: Sendable {
    private struct Window {
        var startedAt: Date
        var lastAt: Date
        var attempts: [String: Int] = [:]
        var failures: [String: Int] = [:]
        var reasons: [String: [String: Int]] = [:]
    }

    private let windowDuration: TimeInterval
    private let minimumAttempts: Int
    private let minimumFailures: Int
    private let minimumFailureRate: Double
    private var window: Window?

    public init(
        windowDuration: TimeInterval = 600,
        minimumAttempts: Int = 20,
        minimumFailures: Int = 5,
        minimumFailureRate: Double = 0.1
    ) {
        self.windowDuration = windowDuration
        self.minimumAttempts = minimumAttempts
        self.minimumFailures = minimumFailures
        self.minimumFailureRate = minimumFailureRate
    }

    /// 抽 `outbound/anytls[node-xxx]` 里方括号中的 tag。
    ///
    /// `direct` 与 `reject` 一律不计：前者是直连、不代表节点健康，后者是**规则主动拒绝**
    /// （广告拦截每命中一次就是一条 `operation not permitted`），把它算成失败会让
    /// 开着广告拦截的用户天天收到"节点故障"误报。
    public static func outboundTag(in message: String) -> String? {
        guard let range = message.range(of: "outbound/") else { return nil }
        let tail = message[range.upperBound...]
        guard let open = tail.firstIndex(of: "["), let close = tail[open...].firstIndex(of: "]") else {
            return nil
        }
        let tag = String(tail[tail.index(after: open)..<close])
        guard !tag.isEmpty, tag != "direct", tag != "reject", tag != "block" else { return nil }
        return tag
    }

    /// 成功建连。内核对每条成功的出站连接都写一行 `outbound connection to <host>`。
    public static func isSuccessfulAttempt(_ line: CoreLogLine) -> Bool {
        line.message.contains("outbound connection to")
    }

    /// 会话建立失败。只认**建连阶段**的失败；连接建成后再断开是另一回事，
    /// 不该算进"节点连不上"的口径。
    public static func isFailedAttempt(_ line: CoreLogLine) -> Bool {
        let text = line.message
        guard text.contains("open connection to"), text.contains(" using outbound/") else { return false }
        // `context canceled` 是**配置重载时主动取消旧连接**，不是节点故障。
        // 真机样本里它占 30 条；算进去的话用户每改一次设置就会收到一次"节点故障"误报。
        guard !text.contains("context canceled") else { return false }
        return failureMarkers.contains { text.contains($0) }
    }

    private static let failureMarkers = [
        "failed to create session",
        "i/o timeout",
        "connection refused",
        "connection reset by peer",
        "network is unreachable",
        "no route to host"
    ]

    /// 归一化失败原因，用于聚类展示。
    ///
    /// 先把地址整体抹掉再取尾段，**保证 IP 与端口不可能残留**——那是用户机场/自建服务器
    /// 的地址，不该进持久化且可导出的运行事件。真机样本的四种形态都会落到有意义的尾段：
    /// `dial tcp <addr>: connect: connection refused` → `connection refused`；
    /// `failed to create session: EOF` → `EOF`；
    /// `read tcp <addr>-><addr>: read: connection reset by peer` → `connection reset by peer`。
    static func normalizedReason(from message: String) -> String {
        var text = message
        if let range = text.range(of: "using outbound/") {
            text = String(text[range.upperBound...])
            if let colon = text.range(of: "]: ") { text = String(text[colon.upperBound...]) }
        }
        text = text.replacingOccurrences(
            of: "[0-9a-fA-F.:]+:[0-9]+",
            with: "<addr>",
            options: .regularExpression
        )
        let segments = text.components(separatedBy: ": ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "<addr>" && !$0.hasPrefix("dial tcp") && !$0.hasPrefix("read tcp") }
        guard let last = segments.last, !last.isEmpty else { return "未知原因" }
        return last
    }

    public mutating func ingest(_ line: CoreLogLine, at date: Date) -> OutboundFailureReport? {
        let success = Self.isSuccessfulAttempt(line)
        let failure = Self.isFailedAttempt(line)
        guard success || failure, let tag = Self.outboundTag(in: line.message) else {
            return flush(at: date)
        }

        let expired = flush(at: date)
        var current = window ?? Window(startedAt: date, lastAt: date)
        current.attempts[tag, default: 0] += 1
        if failure {
            current.failures[tag, default: 0] += 1
            let reason = Self.normalizedReason(from: line.message)
            current.reasons[tag, default: [:]][reason, default: 0] += 1
        }
        current.lastAt = date
        window = current
        return expired
    }

    /// 窗口到期就结算。没有新日志时也要由调用方周期性调用。
    public mutating func flush(at date: Date) -> OutboundFailureReport? {
        guard let current = window,
              date.timeIntervalSince(current.startedAt) >= windowDuration else { return nil }
        return settle(current)
    }

    private mutating func settle(_ current: Window) -> OutboundFailureReport? {
        window = nil

        // 只报最糟的那个出站：一次弹一条，用户才看得下去。
        let worst = current.failures
            .filter { tag, failures in
                let attempts = current.attempts[tag] ?? 0
                return attempts >= minimumAttempts
                    && failures >= minimumFailures
                    && Double(failures) / Double(attempts) >= minimumFailureRate
            }
            .max { lhs, rhs in
                let l = Double(lhs.value) / Double(current.attempts[lhs.key] ?? 1)
                let r = Double(rhs.value) / Double(current.attempts[rhs.key] ?? 1)
                return l < r
            }
        guard let worst else { return nil }

        let reasons = current.reasons[worst.key] ?? [:]
        return OutboundFailureReport(
            windowStart: current.startedAt,
            windowEnd: current.lastAt,
            outboundTag: worst.key,
            failures: worst.value,
            attempts: current.attempts[worst.key] ?? worst.value,
            distinctReasonCount: reasons.count,
            dominantReason: reasons.max { $0.value < $1.value }?.key ?? "未知原因"
        )
    }

    /// 不结算地清空。仅用于确实不该出报告的场景；内核停止请用 `finish`——
    /// 直接丢弃未到期的窗口，等于在故障最严重时销毁唯一的证据。
    public mutating func reset() {
        window = nil
    }

    /// 内核停止/重启时**先结算再清空**。
    ///
    /// 故障最严重的形态恰恰是「一开就全失败、用户几十秒内手动关掉」——窗口远没到 600 秒。
    /// 真机 2026-09-02 22:41：节点 276 次建连全失败，52 秒后用户关掉代理，
    /// 而 `reset()` 把窗口整个丢掉，消息页一条记录都没有。
    public mutating func finish(at date: Date) -> OutboundFailureReport? {
        guard let current = window else { return nil }
        return settle(current)
    }
}
