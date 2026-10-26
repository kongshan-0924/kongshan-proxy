import Darwin
import Foundation

public struct DNSSettings: Codable, Equatable, Sendable {
    /// 国内 DNS：填 IP 走 UDP 53，填 `https://` 地址走 DoH。
    ///
    /// 默认是 UDP。DoH 是一条 HTTP/2 长连接，睡眠或长时间闲置后被 NAT 悄悄回收，sing-box 察觉不到，
    /// 唤醒后第一批国内查询要在死连接上等到超时（真机约 10 秒）才重建；保活只能缓解闲置、管不了睡眠。
    /// UDP 每次查询独立收发，没有这个状态。国内查询走明文的代价小：直连站点的 TLS SNI 本就对运营商可见。
    public var domesticDNS: String
    public var remoteDoH: String
    /// 引导解析器（UDP 53，无连接）。留空 = 跟随国内 DNS 的 IP（隐私意图：
    /// 用户换掉阿里后，节点域名解析也不再问阿里）；非空 = 指定独立上游，
    /// 与国内 DNS 解耦——一台上游抖动不会同时打掉「节点域名解析」与「国内域名解析」。
    public var bootstrapResolver: String

    public init(domesticDNS: String, remoteDoH: String, bootstrapResolver: String = "") {
        self.domesticDNS = domesticDNS
        self.remoteDoH = remoteDoH
        self.bootstrapResolver = bootstrapResolver
    }

    public static let defaults = DNSSettings(
        domesticDNS: "223.5.5.5",
        remoteDoH: "https://8.8.8.8/dns-query"
    )

    /// 0.2.17 及以前的默认国内 DNS。读到它就换成新默认（同一台阿里 DNS 改走 UDP）；
    /// 用户自己改过的 DoH 地址原样保留——那是有意的选择。
    static let legacyDefaultDomesticDoH = "https://223.5.5.5/dns-query"

    /// JSON 键名沿用旧的 `domesticDoH`，老 settings.json 不必迁移键。
    private enum CodingKeys: String, CodingKey {
        case domesticDNS = "domesticDoH"
        case remoteDoH
        case bootstrapResolver
    }

    /// 旧版 settings.json 没有 bootstrapResolver 字段。合成的 init(from:) 对缺失的非可选
    /// 属性会整体解码失败——那等于升级一次就丢掉全部 DNS 设置，所以必须手写兼容。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let domestic = try container.decode(String.self, forKey: .domesticDNS)
        domesticDNS = domestic == Self.legacyDefaultDomesticDoH ? Self.defaults.domesticDNS : domestic
        remoteDoH = try container.decode(String.self, forKey: .remoteDoH)
        bootstrapResolver = try container.decodeIfPresent(String.self, forKey: .bootstrapResolver) ?? ""
    }

    public func validated() throws -> DNSSettings {
        let domestic = domesticDNS.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteDoH.trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrap = bootstrapResolver.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Self.domesticResolver(domestic)
        _ = try Self.endpoint(remote, field: .remote)
        if !bootstrap.isEmpty, !Self.isIPAddress(bootstrap) {
            throw DNSSettingsError.invalidBootstrapResolver
        }
        return DNSSettings(
            domesticDNS: domestic,
            remoteDoH: remote,
            bootstrapResolver: bootstrap
        )
    }

    /// 内核解析节点域名用的那台 UDP 上游（与 `ConfigGenerator` 里 `dns-bootstrap` 的选址一致）：
    /// 用户指定的引导解析器；没指定时跟随国内 DNS 的 IP；国内 DNS 是域名形式的 DoH 时为 nil（内核退到 223.5.5.5）。
    public var nodeResolverAddress: String? {
        let bootstrap = bootstrapResolver.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bootstrap.isEmpty { return Self.isIPAddress(bootstrap) ? bootstrap : nil }
        return (try? endpoints().domestic)?.ipAddress
    }

    func endpoints() throws -> (domestic: DomesticResolver, remote: DoHEndpoint) {
        let settings = try validated()
        return (
            try Self.domesticResolver(settings.domesticDNS),
            try Self.endpoint(settings.remoteDoH, field: .remote)
        )
    }

    private static func domesticResolver(_ value: String) throws -> DomesticResolver {
        if isIPAddress(value) { return .udp(value) }
        guard value.lowercased().hasPrefix("https://") else { throw DNSSettingsError.invalidURL(.domestic) }
        return .doh(try endpoint(value, field: .domestic))
    }

    private static func endpoint(_ value: String, field: DNSSettingsError.Field) throws -> DoHEndpoint {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              !components.percentEncodedPath.isEmpty else {
            throw DNSSettingsError.invalidURL(field)
        }

        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery, !query.isEmpty {
            path += "?\(query)"
        }
        return DoHEndpoint(
            host: host,
            port: components.port,
            path: path,
            hostIsIPAddress: isIPAddress(host)
        )
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }
}

public enum DNSSettingsError: Error, Equatable, LocalizedError {
    public enum Field: String, Equatable, Sendable {
        case domestic
        case remote
    }

    case invalidURL(Field)
    case invalidBootstrapResolver

    public var errorDescription: String? {
        switch self {
        case .invalidURL(.domestic):
            "国内 DNS 必须是 IP 地址（走 UDP 53）或有效的 HTTPS DoH 地址"
        case .invalidURL(.remote):
            "远程 DNS 必须是有效的 HTTPS DoH 地址"
        case .invalidBootstrapResolver:
            "引导解析器必须是 IP 地址（IPv4 或 IPv6），留空则跟随国内 DNS"
        }
    }
}

enum DomesticResolver: Sendable {
    case udp(String)
    case doh(DoHEndpoint)

    var ipAddress: String? {
        switch self {
        case let .udp(address): address
        case let .doh(endpoint): endpoint.hostIsIPAddress ? endpoint.host : nil
        }
    }
}

struct DoHEndpoint: Sendable {
    let host: String
    let port: Int?
    let path: String
    let hostIsIPAddress: Bool
}
