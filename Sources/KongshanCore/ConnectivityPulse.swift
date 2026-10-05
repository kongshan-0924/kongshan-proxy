import Foundation

/// 最近一段时间里「直连 / 经节点」建连的成败，按 10 秒一格记账。
///
/// 存在的理由：DNS 突发超时告警原先只看网卡收发量来区分「解析器坏了」与「整机断网」。
/// 真机 2026-10-05 04:00 外网断了约 1.5 分钟，Wi-Fi 一直连着、局域网照样有流量，告警却写
/// 「期间网卡仍收发 17.4 MB，链路正常，问题在被查询的解析器」——同一时段直连与节点建连其实全在超时。
/// 出站失败检测器按 10 分钟汇总，一分多钟的断网会被前后正常的连接冲淡，所以另记一份带时间的。
public struct ConnectivityPulse: Sendable {
    public struct Tally: Equatable, Sendable {
        public var attempts = 0
        public var failures = 0

        public init(attempts: Int = 0, failures: Int = 0) {
            self.attempts = attempts
            self.failures = failures
        }

        public var failureRate: Double { attempts == 0 ? 0 : Double(failures) / Double(attempts) }
    }

    private struct Bucket {
        var start: Date
        var direct = Tally()
        var proxied = Tally()
    }

    static let bucketSize: TimeInterval = 10
    /// 留 15 分钟：突发窗口 2 分钟，报告在窗口到期时才出，足够回看。
    static let retention: TimeInterval = 15 * 60

    private var buckets: [Bucket] = []
    /// 按连接 ID 去重：内核拨号开始与成功各写一行「outbound connection to」，不能算两次尝试。
    private var countedAttempts: [String: Date] = [:]
    private var countedFailures: [String: Date] = [:]

    public init() {}

    public mutating func ingest(_ line: CoreLogLine, at date: Date) {
        let isDirect = OutboundFailureDetector.isDirectOutbound(line)
        guard isDirect || OutboundFailureDetector.outboundTag(in: line.message) != nil else { return }
        let failed = OutboundFailureDetector.isFailedAttempt(line)
        guard failed || OutboundFailureDetector.isAttemptLine(line) else { return }
        prune(before: date.addingTimeInterval(-Self.retention))

        var attempt = false
        var failure = false
        if let id = line.connectionID {
            if countedAttempts[id] == nil {
                countedAttempts[id] = date
                attempt = true
            }
            if failed, countedFailures[id] == nil {
                countedFailures[id] = date
                failure = true
            }
        } else {
            attempt = true
            failure = failed
        }
        guard attempt || failure else { return }

        let start = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / Self.bucketSize).rounded(.down) * Self.bucketSize)
        if buckets.last?.start != start {
            buckets.append(Bucket(start: start))
        }
        let index = buckets.count - 1
        if isDirect {
            if attempt { buckets[index].direct.attempts += 1 }
            if failure { buckets[index].direct.failures += 1 }
        } else {
            if attempt { buckets[index].proxied.attempts += 1 }
            if failure { buckets[index].proxied.failures += 1 }
        }
    }

    /// `[from, to]` 里（按 10 秒格对齐）的直连与经节点建连统计。
    public func tallies(from: Date, to: Date) -> (direct: Tally, proxied: Tally) {
        var direct = Tally()
        var proxied = Tally()
        for bucket in buckets where bucket.start.addingTimeInterval(Self.bucketSize) > from && bucket.start <= to {
            direct.attempts += bucket.direct.attempts
            direct.failures += bucket.direct.failures
            proxied.attempts += bucket.proxied.attempts
            proxied.failures += bucket.proxied.failures
        }
        return (direct, proxied)
    }

    private mutating func prune(before cutoff: Date) {
        if let first = buckets.first, first.start < cutoff {
            buckets.removeAll { $0.start.addingTimeInterval(Self.bucketSize) < cutoff }
        }
        if countedAttempts.count > 4_096 {
            countedAttempts = countedAttempts.filter { $0.value >= cutoff }
            countedFailures = countedFailures.filter { $0.value >= cutoff }
        }
    }
}

/// DNS 突发超时时，同一时段的建连情况说明的是什么。
public enum DNSStallCause: Equatable, Sendable {
    /// 直连也大量失败（有节点样本时节点也一样）：本机网络整体不通，不是解析器的问题。
    case networkDown
    /// 同期建连基本正常：问题在被查询的解析器。
    case resolver
    /// 样本不够，下不了结论。
    case undetermined

    /// 判定门槛：一类至少 3 次尝试才算有样本；失败过半算「在失败」，两成以下算「正常」。
    public static func classify(direct: ConnectivityPulse.Tally, proxied: ConnectivityPulse.Tally) -> DNSStallCause {
        let minimum = 3
        let directFailing = direct.attempts >= minimum && direct.failureRate >= 0.5
        let proxiedFailing = proxied.attempts >= minimum && proxied.failureRate >= 0.5
        // 直连失败过半就是本机出口的问题；节点那边若有样本也得一起在失败，才排除「只是直连某站坏了」。
        if directFailing && (proxied.attempts < minimum || proxiedFailing) {
            return .networkDown
        }
        let total = ConnectivityPulse.Tally(
            attempts: direct.attempts + proxied.attempts,
            failures: direct.failures + proxied.failures
        )
        if total.attempts >= 5, total.failureRate < 0.2 {
            return .resolver
        }
        return .undetermined
    }
}
