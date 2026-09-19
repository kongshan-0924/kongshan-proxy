import Foundation
import Network

/// 一个局域网客户端的实时用量。
///
/// 累计字节在客户端断开后**继续保留**：用户打开共享页多半是想知道"刚才是谁在用、用了多少"，
/// 连接一断就抹掉等于什么都看不到。
public struct LANClientStats: Identifiable, Equatable, Sendable {
    public let address: String
    public let activeConnections: Int
    /// 客户端 → 代理方向的累计字节（对客户端而言是上传）。
    public let upload: Int64
    /// 代理 → 客户端方向的累计字节。
    public let download: Int64
    public let firstSeenAt: Date
    public let lastActiveAt: Date

    public var id: String { address }
    public var total: Int64 { upload + download }

    public init(
        address: String,
        activeConnections: Int,
        upload: Int64,
        download: Int64,
        firstSeenAt: Date,
        lastActiveAt: Date
    ) {
        self.address = address
        self.activeConnections = activeConnections
        self.upload = upload
        self.download = download
        self.firstSeenAt = firstSeenAt
        self.lastActiveAt = lastActiveAt
    }
}

/// 带速率的客户端行，供界面直接展示。速率由 `LANClientRateTracker` 按两次采样的差值算出。
public struct LANClientLiveStats: Identifiable, Equatable, Sendable {
    public let stats: LANClientStats
    public let uploadRate: Int64
    public let downloadRate: Int64

    public var id: String { stats.address }
    public var address: String { stats.address }
    public var totalRate: Int64 { uploadRate + downloadRate }

    public init(stats: LANClientStats, uploadRate: Int64, downloadRate: Int64) {
        self.stats = stats
        self.uploadRate = uploadRate
        self.downloadRate = downloadRate
    }
}

/// 由累计字节推速率。与内核连接用的 `ConnectionRateTracker` 同一套路：
/// 只有拿到**同一个客户端的前后两次**采样才给速率，否则第一次就会把累计量当成瞬时速率报出去。
public struct LANClientRateTracker: Sendable {
    private struct Sample: Sendable {
        let upload: Int64
        let download: Int64
        let timestamp: Date
    }

    private var previous: [String: Sample] = [:]

    public init() {}

    public mutating func update(_ clients: [LANClientStats], at now: Date) -> [LANClientLiveStats] {
        var next: [String: Sample] = [:]
        var result: [LANClientLiveStats] = []
        result.reserveCapacity(clients.count)

        for client in clients {
            let sample = Sample(upload: client.upload, download: client.download, timestamp: now)
            next[client.address] = sample
            guard let last = previous[client.address] else {
                result.append(LANClientLiveStats(stats: client, uploadRate: 0, downloadRate: 0))
                continue
            }
            let elapsed = now.timeIntervalSince(last.timestamp)
            guard elapsed > 0.05 else {
                result.append(LANClientLiveStats(stats: client, uploadRate: 0, downloadRate: 0))
                continue
            }
            // 计数只增不减；真出现回退（客户端条目被淘汰后重建）时按 0 算，不报负数。
            let up = max(client.upload - last.upload, 0)
            let down = max(client.download - last.download, 0)
            result.append(LANClientLiveStats(
                stats: client,
                uploadRate: Int64(Double(up) / elapsed),
                downloadRate: Int64(Double(down) / elapsed)
            ))
        }
        previous = next
        return result
    }

    public mutating func reset() {
        previous.removeAll()
    }
}

/// 允许接入的来源。
///
/// **基线永远是"必须为私网"**，白名单只在私网之内再收紧一层。
/// 绑 0.0.0.0 意味着端口跟着每一张网卡走，机器拿到公网 IP 时（直连光猫、云主机、开热点）
/// 不设这条基线就等于把开放代理挂到互联网上。
public struct LANPeerPolicy: Equatable, Sendable {
    /// 允许的网段。空表示"全部私网地址"。
    public let allowedCIDRs: [String]

    public init(allowedCIDRs: [String] = []) {
        self.allowedCIDRs = allowedCIDRs
    }

    public func allows(_ endpoint: NWEndpoint) -> Bool {
        guard LocalTCPRelay.isPrivatePeer(endpoint) else { return false }
        guard !allowedCIDRs.isEmpty else { return true }
        guard let address = Self.ipv4Text(of: endpoint) else {
            // 白名单是 IPv4 语义；填了白名单还从 IPv6 进来的一律不放行，
            // 宁可拒错也不要放出一个白名单管不住的口子。
            return false
        }
        return allowedCIDRs.contains { Self.matches(address, cidr: $0) }
    }

    /// `192.168.1.0/24` 或单个地址 `192.168.1.7`。写不出合法形式的条目一律不匹配，
    /// 不做"猜测性放行"。
    public static func matches(_ address: String, cidr: String) -> Bool {
        let trimmed = cidr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let target = ipv4Value(address) else { return false }
        let parts = trimmed.split(separator: "/", maxSplits: 1)
        guard let base = ipv4Value(String(parts[0])) else { return false }
        guard parts.count == 2 else { return base == target }
        guard let bits = Int(parts[1]), (0...32).contains(bits) else { return false }
        if bits == 0 { return true }
        let mask: UInt32 = bits == 32 ? .max : ~(UInt32.max >> UInt32(bits))
        return (base & mask) == (target & mask)
    }

    static func ipv4Value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let byte = UInt32(part), byte <= 255 else { return nil }
            value = (value << 8) | byte
        }
        return value
    }

    static func ipv4Text(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        switch host {
        case let .ipv4(address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case let .ipv6(address):
            // IPv4 映射地址（::ffff:a.b.c.d）按其 IPv4 部分算。
            let bytes = address.rawValue.map { $0 }
            guard bytes.count == 16, bytes.prefix(10).allSatisfy({ $0 == 0 }),
                  bytes[10] == 0xFF, bytes[11] == 0xFF else { return nil }
            return bytes[12...].map { String($0) }.joined(separator: ".")
        default:
            return nil
        }
    }
}

/// 局域网共享的可配置项。
public struct LANSharingSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// 期望的监听端口。与本机代理入口**分开**，改它不影响系统代理。
    public var port: UInt16
    /// 允许接入的网段。空＝全部私网。无论如何都不放行公网来源。
    public var allowedCIDRs: [String]

    public static let defaults = LANSharingSettings(enabled: false, port: 7890, allowedCIDRs: [])

    public init(enabled: Bool, port: UInt16, allowedCIDRs: [String]) {
        self.enabled = enabled
        self.port = port
        self.allowedCIDRs = allowedCIDRs
    }

    /// 校验并规范化。
    ///
    /// 端口下限取 1024：低端口要 root 才能绑，这个进程绑不了，让用户填了再失败不如直接拒。
    /// 上限避开 macOS 的临时源端口池（49152 起），否则会与系统随机分配的源端口撞。
    public func validated() throws -> LANSharingSettings {
        guard (1024...49151).contains(Int(port)) else {
            throw LANSharingError.portOutOfRange
        }
        var cleaned: [String] = []
        for raw in allowedCIDRs {
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            guard LANPeerPolicy.matches(value.split(separator: "/").first.map(String.init) ?? value, cidr: value) else {
                throw LANSharingError.invalidCIDR(value)
            }
            if !cleaned.contains(value) { cleaned.append(value) }
        }
        return LANSharingSettings(enabled: enabled, port: port, allowedCIDRs: cleaned)
    }
}

public enum LANSharingError: Error, LocalizedError, Equatable {
    case portOutOfRange
    case invalidCIDR(String)

    public var errorDescription: String? {
        switch self {
        case .portOutOfRange:
            "局域网端口需在 1024–49151 之间：更低的端口要管理员权限才能监听，更高的会与系统随机源端口冲突"
        case let .invalidCIDR(value):
            "网段写法无效：\(value)。请填 192.168.1.0/24 这样的网段，或 192.168.1.7 这样的单个地址"
        }
    }
}
