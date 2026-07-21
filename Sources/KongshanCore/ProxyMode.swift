import Foundation

public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case systemProxy
    case tun
}

/// 出站模式：决定流量如何选择出口，与「接管方式」正交。
/// 顺序即界面展示顺序，对齐 Stash 的 直连 / 规则 / 全局。
public enum OutboundMode: String, Codable, CaseIterable, Sendable {
    /// 全部直连，不经过代理。
    case direct
    /// 按分流规则走（默认）。
    case rule
    /// 全部走代理，忽略分流规则。
    case global

    public var displayName: String {
        switch self {
        case .rule: "规则"
        case .global: "全局"
        case .direct: "直连"
        }
    }

    public var detail: String {
        switch self {
        case .rule: "按「规则」页的分流配置决定直连或代理"
        case .global: "所有流量都走代理，忽略分流规则"
        case .direct: "所有流量都直连，代理仍在运行但不接管出口"
        }
    }
}

/// TUN 协议栈。官方 darwin-arm64 二进制带 gVisor，三种都可用。
/// system 栈在 macOS 15.2 / 26.x 上有多起翻车记录（sing-box#2500/#3529），
/// 默认用 mixed：TCP 走 gVisor、UDP 走 system，兼容性最好。
public enum TunStack: String, Codable, CaseIterable, Sendable {
    case mixed
    case system
    case gvisor

    public var displayName: String {
        switch self {
        case .mixed: "mixed（推荐）"
        case .system: "system"
        case .gvisor: "gVisor"
        }
    }
}

public struct TunSettings: Codable, Equatable, Sendable {
    public var strictRoute: Bool
    public var interfaceName: String
    public var addresses: [String]
    public var mtu: Int
    public var stack: TunStack

    public init(
        strictRoute: Bool,
        interfaceName: String,
        addresses: [String],
        mtu: Int,
        stack: TunStack = .mixed
    ) {
        self.strictRoute = strictRoute
        self.interfaceName = interfaceName
        self.addresses = addresses
        self.mtu = mtu
        self.stack = stack
    }

    /// 旧版设置文件没有 stack 字段，按默认 mixed 补齐。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        strictRoute = try container.decode(Bool.self, forKey: .strictRoute)
        interfaceName = try container.decode(String.self, forKey: .interfaceName)
        addresses = try container.decode([String].self, forKey: .addresses)
        mtu = try container.decode(Int.self, forKey: .mtu)
        stack = try container.decodeIfPresent(TunStack.self, forKey: .stack) ?? .mixed
    }

    public static let defaults = TunSettings(
        strictRoute: false,
        interfaceName: "kongshan-tun",
        addresses: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        mtu: 9_000
    )

    /// TUN 模式下系统 DNS 要指向的地址：取第一个 IPv4 网段里接口地址的下一跳
    /// （172.19.0.1/30 → 172.19.0.2）。它不是接口自身地址——发往接口地址的包
    /// 走本机回环，进不了 TUN；下一跳地址才会被路由进 TUN 并被 hijack-dns 截获。
    public var dnsServerAddress: String {
        for address in addresses {
            let host = address.split(separator: "/").first.map(String.init) ?? address
            var parts = host.split(separator: ".").map(String.init)
            guard parts.count == 4, let last = Int(parts[3]), last < 254 else { continue }
            parts[3] = String(last + 1)
            return parts.joined(separator: ".")
        }
        return "172.19.0.2"
    }
}
