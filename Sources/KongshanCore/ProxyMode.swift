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

public struct TunSettings: Codable, Equatable, Sendable {
    public var strictRoute: Bool
    public var addresses: [String]
    public var mtu: Int

    public init(
        strictRoute: Bool,
        addresses: [String],
        mtu: Int
    ) {
        self.strictRoute = strictRoute
        self.addresses = addresses
        self.mtu = mtu
    }

    public static let defaults = TunSettings(
        strictRoute: false,
        addresses: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        mtu: 9_000
    )

    /// TUN 模式下系统 DNS 要指向接口自身的 IPv4 地址。
    /// macOS 原生 TUN 只为该地址建立本地路由；指向同网段的下一跳会绕到物理网关，
    /// 无法被 sing-box 的 hijack-dns 接管。
    public var dnsServerAddress: String {
        for address in addresses {
            let host = address.split(separator: "/").first.map(String.init) ?? address
            let parts = host.split(separator: ".")
            guard parts.count == 4, parts.allSatisfy({
                guard let octet = Int($0) else { return false }
                return (0...255).contains(octet)
            }) else { continue }
            return host
        }
        return "172.19.0.1"
    }

    /// 返回去掉 IPv6 地址后的副本。物理网络没有全局 IPv6 时，
    /// 给 TUN 配 IPv6 会让应用尝试 IPv6 直连，但 direct 出站无法到达
    /// （en0 无全局 IPv6）→ "no route to host" → 应用不快速回退 IPv4 → 网断。
    /// 剥掉后应用看不到 TUN 上的 IPv6，自然走 IPv4，DNS 仍照常解析 AAAA
    /// 供代理出站使用。
    public func stripIPv6() -> TunSettings {
        let onlyIPv4 = addresses.filter { !$0.contains(":") }
        guard onlyIPv4.count != addresses.count else { return self }
        var copy = self
        copy.addresses = onlyIPv4.isEmpty ? ["172.19.0.1/30"] : onlyIPv4
        return copy
    }
}
