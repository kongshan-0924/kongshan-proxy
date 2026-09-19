import Darwin
import Foundation

public struct DNSSettings: Codable, Equatable, Sendable {
    public var domesticDoH: String
    public var remoteDoH: String
    /// 引导解析器（UDP 53，无连接）。留空 = 跟随国内 DoH 的 IP（隐私意图：
    /// 用户换掉阿里后，节点域名解析也不再问阿里）；非空 = 指定独立上游，
    /// 与国内 DoH 解耦——一台上游抖动不会同时打掉「节点域名解析」与「国内域名解析」。
    public var bootstrapResolver: String

    public init(domesticDoH: String, remoteDoH: String, bootstrapResolver: String = "") {
        self.domesticDoH = domesticDoH
        self.remoteDoH = remoteDoH
        self.bootstrapResolver = bootstrapResolver
    }

    public static let defaults = DNSSettings(
        domesticDoH: "https://223.5.5.5/dns-query",
        remoteDoH: "https://8.8.8.8/dns-query"
    )

    /// 旧版 settings.json 没有 bootstrapResolver 字段。合成的 init(from:) 对缺失的非可选
    /// 属性会整体解码失败——那等于升级一次就丢掉全部 DNS 设置，所以必须手写兼容。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domesticDoH = try container.decode(String.self, forKey: .domesticDoH)
        remoteDoH = try container.decode(String.self, forKey: .remoteDoH)
        bootstrapResolver = try container.decodeIfPresent(String.self, forKey: .bootstrapResolver) ?? ""
    }

    public func validated() throws -> DNSSettings {
        let domestic = domesticDoH.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteDoH.trimmingCharacters(in: .whitespacesAndNewlines)
        let bootstrap = bootstrapResolver.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Self.endpoint(domestic, field: .domestic)
        _ = try Self.endpoint(remote, field: .remote)
        if !bootstrap.isEmpty, !Self.isIPAddress(bootstrap) {
            throw DNSSettingsError.invalidBootstrapResolver
        }
        return DNSSettings(
            domesticDoH: domestic,
            remoteDoH: remote,
            bootstrapResolver: bootstrap
        )
    }

    func endpoints() throws -> (domestic: DoHEndpoint, remote: DoHEndpoint) {
        let settings = try validated()
        return (
            try Self.endpoint(settings.domesticDoH, field: .domestic),
            try Self.endpoint(settings.remoteDoH, field: .remote)
        )
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
            "国内 DNS 必须是有效的 HTTPS DoH 地址"
        case .invalidURL(.remote):
            "远程 DNS 必须是有效的 HTTPS DoH 地址"
        case .invalidBootstrapResolver:
            "引导解析器必须是 IP 地址（IPv4 或 IPv6），留空则跟随国内 DoH"
        }
    }
}

struct DoHEndpoint: Sendable {
    let host: String
    let port: Int?
    let path: String
    let hostIsIPAddress: Bool
}
