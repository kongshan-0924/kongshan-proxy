import Darwin
import Foundation

public enum CustomRuleType: String, Codable, CaseIterable, Hashable, Sendable {
    case domainSuffix
    case domainKeyword
    case domain
    case ipCIDR
    case processName

    public var displayName: String {
        switch self {
        case .domainSuffix: "域名后缀"
        case .domainKeyword: "域名关键词"
        case .domain: "完整域名"
        case .ipCIDR: "IP CIDR"
        case .processName: "进程名"
        }
    }
}

public enum RouteAction: String, Codable, CaseIterable, Hashable, Sendable {
    case direct
    case proxy
    case reject

    public var displayName: String {
        switch self {
        case .direct: "直连"
        case .proxy: "代理"
        case .reject: "拒绝"
        }
    }
}

public struct CustomRouteRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var order: Int
    public var enabled: Bool
    public var type: CustomRuleType
    public var value: String
    public var action: RouteAction
    public var proxyGroup: String?

    public init(
        id: UUID = UUID(),
        order: Int,
        enabled: Bool = true,
        type: CustomRuleType,
        value: String,
        action: RouteAction,
        proxyGroup: String? = nil
    ) {
        self.id = id
        self.order = order
        self.enabled = enabled
        self.type = type
        self.value = value
        self.action = action
        self.proxyGroup = proxyGroup
    }

    public func validated() throws -> CustomRouteRule {
        var rule = self
        rule.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.value.isEmpty else { throw RoutingValidationError.emptyRuleValue }
        if type == .ipCIDR, !Self.isValidCIDR(rule.value) {
            throw RoutingValidationError.invalidCIDR(rule.value)
        }
        if action == .proxy {
            let group = proxyGroup?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !group.isEmpty else { throw RoutingValidationError.missingProxyGroup }
            rule.proxyGroup = group
        } else {
            rule.proxyGroup = nil
        }
        return rule
    }

    static func isValidCIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return false }
        let address = String(parts[0])
        if address.contains(":") {
            guard (0...128).contains(prefix) else { return false }
            var storage = in6_addr()
            return address.withCString { inet_pton(AF_INET6, $0, &storage) } == 1
        } else {
            guard (0...32).contains(prefix) else { return false }
            var storage = in_addr()
            return address.withCString { inet_pton(AF_INET, $0, &storage) } == 1
        }
    }
}

public struct RoutingSettings: Codable, Equatable, Sendable {
    public var customRules: [CustomRouteRule]
    public var bypassDomains: [String]
    public var bypassCIDRs: [String]
    public var blockAds: Bool

    public init(
        customRules: [CustomRouteRule],
        bypassDomains: [String],
        bypassCIDRs: [String],
        blockAds: Bool
    ) {
        self.customRules = customRules
        self.bypassDomains = bypassDomains
        self.bypassCIDRs = bypassCIDRs
        self.blockAds = blockAds
    }

    public static let defaults = RoutingSettings(
        customRules: [],
        bypassDomains: ["localhost", "*.local", "*.cn"],
        bypassCIDRs: [
            "127.0.0.0/8",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
            "::1/128",
            "fc00::/7",
            "fe80::/10"
        ],
        blockAds: false
    )

    public var systemProxyBypassEntries: [String] {
        bypassDomains + bypassCIDRs
    }

    public func validated() throws -> RoutingSettings {
        var settings = self
        settings.customRules = try customRules.map { try $0.validated() }.sorted { $0.order < $1.order }
        settings.bypassDomains = try bypassDomains.map { domain in
            let value = domain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw RoutingValidationError.emptyBypassDomain }
            return value
        }
        settings.bypassCIDRs = try bypassCIDRs.map { cidr in
            let value = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard CustomRouteRule.isValidCIDR(value) else {
                throw RoutingValidationError.invalidCIDR(value)
            }
            return value
        }
        return settings
    }
}

public enum RoutingValidationError: Error, Equatable, LocalizedError {
    case emptyRuleValue
    case invalidCIDR(String)
    case missingProxyGroup
    case emptyBypassDomain

    public var errorDescription: String? {
        switch self {
        case .emptyRuleValue: "规则匹配值不能为空"
        case let .invalidCIDR(value): "IP CIDR 无效：\(value)"
        case .missingProxyGroup: "代理规则必须选择策略组"
        case .emptyBypassDomain: "绕过域名不能为空"
        }
    }
}
