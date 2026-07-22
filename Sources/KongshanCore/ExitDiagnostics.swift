import Foundation

public struct ExitIPInfo: Codable, Equatable, Sendable {
    public let ip: String
    public let country: String
    public let city: String?
    public let organization: String

    public init(ip: String, country: String, city: String?, organization: String) {
        self.ip = ip
        self.country = country
        self.city = city
        self.organization = organization
    }

    public var location: String {
        guard let city, !city.isEmpty else { return country }
        return "\(city), \(country)"
    }
}

public struct DNSResolverInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String { ip }
    public let ip: String
    public let country: String
    public let city: String?
    public let organization: String
    public let isMullvadDNS: Bool

    public init(
        ip: String,
        country: String,
        city: String?,
        organization: String,
        isMullvadDNS: Bool
    ) {
        self.ip = ip
        self.country = country
        self.city = city
        self.organization = organization
        self.isMullvadDNS = isMullvadDNS
    }

    private enum CodingKeys: String, CodingKey {
        case ip
        case country
        case city
        case organization
        case isMullvadDNS = "mullvad_dns"
    }
}

public enum DNSLeakStatus: String, Codable, Equatable, Sendable {
    case clear
    case possible
    case indeterminate
}

public struct DNSLeakAssessment: Codable, Equatable, Sendable {
    public let status: DNSLeakStatus
    public let detail: String

    public init(status: DNSLeakStatus, detail: String) {
        self.status = status
        self.detail = detail
    }
}

public enum DNSLeakAnalyzer {
    public static func deduplicated(_ resolvers: [DNSResolverInfo]) -> [DNSResolverInfo] {
        var seen = Set<String>()
        return resolvers.filter { seen.insert($0.ip).inserted }
    }

    public static func assess(
        exit: ExitIPInfo,
        resolvers: [DNSResolverInfo],
        remoteDoH: String
    ) -> DNSLeakAssessment {
        let resolvers = deduplicated(resolvers)
        guard !resolvers.isEmpty else {
            return DNSLeakAssessment(status: .indeterminate, detail: "未取得 DNS 解析器结果")
        }

        let expectedProviders = expectedProviderKeywords(for: remoteDoH)
        let unexpected = resolvers.filter { resolver in
            if resolver.isMullvadDNS { return false }
            if resolver.country.caseInsensitiveCompare(exit.country) == .orderedSame { return false }
            let organization = resolver.organization.lowercased()
            return !expectedProviders.contains { organization.contains($0) }
        }

        guard !unexpected.isEmpty else {
            return DNSLeakAssessment(
                status: .clear,
                detail: "DNS 解析器与当前出口或远程 DoH 配置一致"
            )
        }

        let names = unexpected.map { resolver in
            resolver.organization.isEmpty ? resolver.ip : resolver.organization
        }
        return DNSLeakAssessment(
            status: .possible,
            detail: "发现与出口/远程 DoH 不一致的解析器：\(names.joined(separator: "、"))"
        )
    }

    private static func expectedProviderKeywords(for remoteDoH: String) -> [String] {
        guard let host = URL(string: remoteDoH)?.host?.lowercased() else { return [] }
        if host.contains("cloudflare") || host == "1.1.1.1" { return ["cloudflare"] }
        if host.contains("google") || host == "8.8.8.8" { return ["google"] }
        if host.contains("quad9") || host == "9.9.9.9" { return ["quad9"] }
        if host.contains("alidns") { return ["alibaba", "alidns"] }
        if host.contains("doh.pub") { return ["tencent"] }
        if host.contains("mullvad") { return ["mullvad"] }
        return []
    }
}
