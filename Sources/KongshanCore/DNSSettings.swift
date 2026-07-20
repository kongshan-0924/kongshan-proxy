import Darwin
import Foundation

public struct DNSSettings: Codable, Equatable, Sendable {
    public var domesticDoH: String
    public var remoteDoH: String

    public init(domesticDoH: String, remoteDoH: String) {
        self.domesticDoH = domesticDoH
        self.remoteDoH = remoteDoH
    }

    public static let defaults = DNSSettings(
        domesticDoH: "https://223.5.5.5/dns-query",
        remoteDoH: "https://8.8.8.8/dns-query"
    )

    public func validated() throws -> DNSSettings {
        let domestic = domesticDoH.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = remoteDoH.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try Self.endpoint(domestic, field: .domestic)
        _ = try Self.endpoint(remote, field: .remote)
        return DNSSettings(domesticDoH: domestic, remoteDoH: remote)
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

    public var errorDescription: String? {
        switch self {
        case .invalidURL(.domestic):
            "国内 DNS 必须是有效的 HTTPS DoH 地址"
        case .invalidURL(.remote):
            "远程 DNS 必须是有效的 HTTPS DoH 地址"
        }
    }
}

struct DoHEndpoint: Sendable {
    let host: String
    let port: Int?
    let path: String
    let hostIsIPAddress: Bool
}
