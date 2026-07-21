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

/// 用户自定义策略组。每个组在配置里生成一个 selector 或 urltest 出站，
/// 自定义规则可以把流量指向它，托盘里也能单独为它指定节点。
public struct PolicyGroup: Identifiable, Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case selector
        case urltest

        public var displayName: String {
            self == .urltest ? "自动选择最快" : "手动指定"
        }
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// 该组包含的成员（节点名 / 其他组名 / DIRECT / REJECT）。
    /// 空表示「全部节点」（用户手建的组即如此）；订阅带出的组保留真实成员列表。
    public var members: [String]

    public init(id: UUID = UUID(), name: String, kind: Kind = .selector, members: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.members = members
    }

    /// 旧版数据没有 members 字段，解码时回落到空（＝全部节点）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        members = try container.decodeIfPresent([String].self, forKey: .members) ?? []
    }

    /// 内置组名不可占用，避免和生成器固定产出的组冲突。
    public static let reservedNames = ["手动选择", "自动选择", "自建", "direct", "reject"]

    public func validated() throws -> PolicyGroup {
        var group = self
        group.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !group.name.isEmpty else { throw RoutingValidationError.emptyPolicyGroupName }
        guard !Self.reservedNames.contains(group.name) else {
            throw RoutingValidationError.reservedPolicyGroupName(group.name)
        }
        // 组名会直接作为 sing-box 的 outbound tag 使用，排除会破坏引用的字符。
        let forbidden = CharacterSet(charactersIn: "\"\\{}[],:\n\t")
        guard group.name.rangeOfCharacter(from: forbidden) == nil, group.name.count <= 40 else {
            throw RoutingValidationError.invalidPolicyGroupName(group.name)
        }
        return group
    }
}

/// 订阅自带的分流规则（Clash 的 `rules:`）。只读，不进入用户自定义规则列表。
public struct SubscriptionRule: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { "\(type.rawValue)|\(value)|\(target)" }
    public var type: CustomRuleType
    public var value: String
    /// DIRECT / REJECT / 策略组名。
    public var target: String

    public init(type: CustomRuleType, value: String, target: String) {
        self.type = type
        self.value = value
        self.target = target
    }

    /// Clash 规则类型 → 我们支持的类型。不支持的返回 nil 并被跳过。
    public static func parse(_ line: String) -> SubscriptionRule? {
        let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 3 else { return nil }
        let type: CustomRuleType
        switch parts[0].uppercased() {
        case "DOMAIN-SUFFIX": type = .domainSuffix
        case "DOMAIN-KEYWORD": type = .domainKeyword
        case "DOMAIN": type = .domain
        case "IP-CIDR", "IP-CIDR6": type = .ipCIDR
        case "PROCESS-NAME": type = .processName
        default: return nil
        }
        let value = parts[1]
        guard !value.isEmpty else { return nil }
        if type == .ipCIDR, !CustomRouteRule.isValidCIDR(value) { return nil }
        return SubscriptionRule(type: type, value: value, target: parts[2])
    }
}

public struct RoutingSettings: Codable, Equatable, Sendable {
    /// 是否把订阅自带的分流规则写入运行配置。默认开启：机场的规则通常正是用户想要的。
    public var useSubscriptionRules: Bool = true
    /// 用户自定义策略组，按服务分流时使用（对应 Stash 的 Netflix / YouTube 等分组）。
    public var policyGroups: [PolicyGroup] = []
    public var customRules: [CustomRouteRule]
    public var bypassDomains: [String]
    public var bypassCIDRs: [String]
    /// 强制跳过 TUN 的网段（写入 tun inbound 的 `route_exclude_address`）。
    /// 与 `bypassCIDRs` 分开：前者决定「不走代理」，这里决定「根本不进虚拟网卡」。
    public var tunExcludeCIDRs: [String]
    public var blockAds: Bool

    public init(
        customRules: [CustomRouteRule],
        bypassDomains: [String],
        bypassCIDRs: [String],
        tunExcludeCIDRs: [String] = RoutingSettings.defaultTunExcludeCIDRs,
        policyGroups: [PolicyGroup] = [],
        blockAds: Bool
    ) {
        self.policyGroups = policyGroups
        self.customRules = customRules
        self.bypassDomains = bypassDomains
        self.bypassCIDRs = bypassCIDRs
        self.tunExcludeCIDRs = tunExcludeCIDRs
        self.blockAds = blockAds
    }

    /// 旧版设置文件没有该字段，解码时回落到默认私有网段，避免升级后 TUN 排除列表变空。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customRules = try container.decode([CustomRouteRule].self, forKey: .customRules)
        bypassDomains = try container.decode([String].self, forKey: .bypassDomains)
        bypassCIDRs = try container.decode([String].self, forKey: .bypassCIDRs)
        tunExcludeCIDRs = try container.decodeIfPresent([String].self, forKey: .tunExcludeCIDRs)
            ?? Self.defaultTunExcludeCIDRs
        policyGroups = try container.decodeIfPresent([PolicyGroup].self, forKey: .policyGroups) ?? []
        useSubscriptionRules = try container.decodeIfPresent(Bool.self, forKey: .useSubscriptionRules) ?? true
        blockAds = try container.decode(Bool.self, forKey: .blockAds)
    }

    public static let defaultTunExcludeCIDRs = [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "224.0.0.0/4",
        "::1/128",
        "fc00::/7",
        "fe80::/10"
    ]

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
        tunExcludeCIDRs: RoutingSettings.defaultTunExcludeCIDRs,
        blockAds: false
    )

    public var systemProxyBypassEntries: [String] {
        bypassDomains + bypassCIDRs
    }

    public func validated() throws -> RoutingSettings {
        var settings = self
        settings.policyGroups = try policyGroups.map { try $0.validated() }
        let names = settings.policyGroups.map(\.name)
        guard Set(names).count == names.count else {
            throw RoutingValidationError.duplicatePolicyGroupName
        }
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
        settings.tunExcludeCIDRs = try tunExcludeCIDRs.map { cidr in
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
    case emptyPolicyGroupName
    case reservedPolicyGroupName(String)
    case duplicatePolicyGroupName
    case invalidPolicyGroupName(String)
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
        case .emptyPolicyGroupName: "策略组名称不能为空"
        case let .reservedPolicyGroupName(name): "「\(name)」是内置策略组名，请换一个"
        case .duplicatePolicyGroupName: "策略组名称不能重复"
        case let .invalidPolicyGroupName(name): "策略组名「\(name)」含有不支持的字符或过长（上限 40）"
        }
    }
}
