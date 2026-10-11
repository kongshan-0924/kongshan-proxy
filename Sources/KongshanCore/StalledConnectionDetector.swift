import Foundation

/// 「连接建好了，却一直收不到对方一个字节」的节点识别。
///
/// 存在的理由：VLESS 这类协议在远端那一跳断了时，客户端这边**没有任何报错**——到节点的连接是通的，
/// 请求也发出去了，只是再也等不到回应，直到 App 自己超时放弃。真机 2026-10-07：自建的「中转→家宽出口」节点
/// 节点约 14% 的请求挂满 10 秒，两小时里内核日志对它 0 条错误，空山的建连失败检测器一无所知，
/// 用户只觉得「总是卡」。
///
/// 判据只用一种几乎不会误判的形态：**发往 443 的 TCP 连接**，客户端已经发出数据（TLS 的 ClientHello），
/// 过了 `stallAge` 秒仍一个字节都没收到。TLS 是客户端先说话、服务器立刻回 ServerHello 的协议，
/// 链路正常时回应在一两秒内必到；长轮询、WebSocket 这类「对方晚点才说话」的都在握手之后，不在这个判据里。
public struct StalledConnectionDetector: Sendable {
    public struct Report: Equatable, Sendable {
        public let outboundTag: String
        /// 窗口内判定为卡住的连接数。
        public let stalled: Int
        /// 窗口内看到收到过数据的连接数（采样到的，短命连接可能漏掉，只作参考）。
        public let healthy: Int
        public let windowStart: Date
        public let windowEnd: Date

        public init(outboundTag: String, stalled: Int, healthy: Int, windowStart: Date, windowEnd: Date) {
            self.outboundTag = outboundTag
            self.stalled = stalled
            self.healthy = healthy
            self.windowStart = windowStart
            self.windowEnd = windowEnd
        }
    }

    /// 一条连接的采样（从 `/connections` 来，与 `ConnectionDetail` 解耦，便于测试）。
    public struct Sample: Equatable, Sendable {
        public let id: String
        public let outboundTag: String?
        public let network: String
        public let port: Int?
        public let upload: Int64
        public let download: Int64
        public let start: Date?

        public init(id: String, outboundTag: String?, network: String, port: Int?, upload: Int64, download: Int64, start: Date?) {
            self.id = id
            self.outboundTag = outboundTag
            self.network = network
            self.port = port
            self.upload = upload
            self.download = download
            self.start = start
        }

        /// 从内核连接详情取：最终出站取链路里的节点（`node-` 开头）；不经节点的（直连 / 拒绝 / DNS）为 nil。
        public init(_ detail: ConnectionDetail) {
            self.init(
                id: detail.id,
                outboundTag: detail.chains.last { $0.hasPrefix("node-") },
                network: detail.network,
                port: ConnectionEndpoint(hostAndPort: detail.host).port,
                upload: detail.upload,
                download: detail.download,
                start: detail.start
            )
        }
    }

    /// 发出数据后这么久还一个字节都没收到，算卡住。正常链路的 TLS 回应在一两秒内；
    /// 真机最慢的正常握手约 1.9 秒（经洛杉矶的节点）。
    public static let stallAge: TimeInterval = 6
    /// 统计窗口与报告门槛：同一节点 10 分钟内卡住 3 条才报。
    public static let window: TimeInterval = 600
    public static let minimumStalled = 3

    private enum Verdict { case pending, healthy, stalled }
    private struct Tracked {
        var tag: String
        var start: Date
        var verdict: Verdict
    }

    private var tracked: [String: Tracked] = [:]
    /// 每个节点窗口内的判定时刻。
    private var stalledAt: [String: [Date]] = [:]
    private var healthyAt: [String: [Date]] = [:]

    public init() {}

    /// 喂一次连接快照，返回这次达到门槛的节点。报过的节点清零重新攒，免得每次采样都报一遍。
    public mutating func ingest(_ samples: [Sample], at now: Date) -> [Report] {
        var present = Set<String>()
        for sample in samples {
            guard let tag = sample.outboundTag, sample.network == "tcp", sample.port == 443 else { continue }
            present.insert(sample.id)
            var entry = tracked[sample.id] ?? Tracked(tag: tag, start: sample.start ?? now, verdict: .pending)
            if entry.verdict == .pending {
                if sample.download > 0 {
                    entry.verdict = .healthy
                    healthyAt[tag, default: []].append(now)
                } else if sample.upload > 0, now.timeIntervalSince(entry.start) >= Self.stallAge {
                    entry.verdict = .stalled
                    stalledAt[tag, default: []].append(now)
                }
            }
            tracked[sample.id] = entry
        }
        // 已经关掉的连接不再跟踪。
        tracked = tracked.filter { present.contains($0.key) }

        let cutoff = now.addingTimeInterval(-Self.window)
        stalledAt = stalledAt.mapValues { $0.filter { $0 > cutoff } }.filter { !$0.value.isEmpty }
        healthyAt = healthyAt.mapValues { $0.filter { $0 > cutoff } }.filter { !$0.value.isEmpty }

        var reports: [Report] = []
        for (tag, times) in stalledAt where times.count >= Self.minimumStalled {
            let healthy = healthyAt[tag] ?? []
            reports.append(Report(
                outboundTag: tag,
                stalled: times.count,
                healthy: healthy.count,
                windowStart: (times + healthy).min() ?? now,
                windowEnd: now
            ))
        }
        for report in reports {
            stalledAt[report.outboundTag] = nil
            healthyAt[report.outboundTag] = nil
        }
        return reports.sorted { $0.outboundTag < $1.outboundTag }
    }

    /// 本机网络整体不通、刚从睡眠醒来时调用：那时所有连接都会卡，与节点无关，攒下的判定作废。
    public mutating func discardPending() {
        stalledAt.removeAll()
        healthyAt.removeAll()
    }

    /// 停止接管 / 换内核：连接 ID 全部作废。
    public mutating func reset() {
        tracked.removeAll()
        discardPending()
    }
}
