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
        if type == .ipCIDR {
            guard let normalized = Self.normalizedCIDR(rule.value) else {
                throw RoutingValidationError.invalidCIDR(rule.value)
            }
            rule.value = normalized
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
        IPNetwork(value) != nil && value.contains("/")
    }

    /// sing-box 的 `ip_cidr` 需要前缀长度；界面允许用户直接输入单个 IP，
    /// 保存时补成主机 CIDR，避免看似添加成功、内核校验却失败。
    public static func normalizedCIDR(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("/") {
            return IPNetwork(value) == nil ? nil : value
        }
        guard let address = normalizedIPAddress(value) else { return nil }
        return address.contains(":") ? "\(address)/128" : "\(address)/32"
    }

    /// OpenSSH 的 Host 规则只接受单个主机地址，不能把 CIDR 伪装成可用的匹配。
    /// 同时用 inet_ntop 统一 IPv6 写法，避免同一地址被重复添加。
    public static func normalizedIPAddress(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("/") else { return nil }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        return nil
    }

    /// 规范化用户输入的域名后缀。接受 `*.example.com` 与末尾根域点，
    /// 但不把 URL、端口或路径悄悄解释成域名。
    public static func normalizedDomainSuffix(_ value: String) -> String? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("*.") { value.removeFirst(2) }
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty, value.count <= 253,
              !value.contains("://"), !value.contains("/"), !value.contains(":"),
              !value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
              normalizedCIDR(value) == nil else {
            return nil
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy(allowed.contains)
        }) else {
            return nil
        }
        return value
    }

    public static func isLoopbackCIDR(_ value: String) -> Bool {
        guard let network = IPNetwork(normalizedCIDR(value) ?? value) else { return false }
        return [IPNetwork("127.0.0.0/8"), IPNetwork("::1/128")]
            .compactMap { $0 }
            .contains { $0.overlaps(network) }
    }

    /// Returns whether a concrete IP address belongs to a CIDR rule.
    /// Shared by the configuration UI's rule tester so its IP semantics stay
    /// identical to validation and TUN-exclusion conflict handling.
    public static func cidr(_ cidr: String, contains address: String) -> Bool {
        guard let network = IPNetwork(normalizedCIDR(cidr) ?? cidr),
              let host = IPNetwork(normalizedCIDR(address) ?? address) else { return false }
        return network.contains(host)
    }

}

public struct SSHProxyTarget: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String { "\(address):\(port)" }
    public var address: String
    public var port: UInt16

    public init(address: String, port: UInt16 = 22) {
        self.address = address
        self.port = port
    }

    public func validated() throws -> SSHProxyTarget {
        guard let address = CustomRouteRule.normalizedIPAddress(address) else {
            throw RoutingValidationError.invalidSSHProxyAddress(address)
        }
        guard !CustomRouteRule.isLoopbackCIDR(address) else {
            throw RoutingValidationError.loopbackForcedProxy
        }
        guard port > 0 else { throw RoutingValidationError.invalidSSHProxyPort(Int(port)) }
        return SSHProxyTarget(address: address, port: port)
    }

    public var hostCIDR: String {
        address.contains(":") ? "\(address)/128" : "\(address)/32"
    }
}

private struct IPNetwork {
    let family: Int32
    let bytes: [UInt8]
    let prefix: Int

    init?(_ value: String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let address = String(parts[0])
        if address.contains(":"), (0...128).contains(prefix) {
            var storage = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &storage) }) == 1 else { return nil }
            family = AF_INET6
            bytes = withUnsafeBytes(of: &storage) { Array($0) }
            self.prefix = prefix
        } else if (0...32).contains(prefix) {
            var storage = in_addr()
            guard address.withCString({ inet_pton(AF_INET, $0, &storage) }) == 1 else { return nil }
            family = AF_INET
            bytes = withUnsafeBytes(of: &storage) { Array($0) }
            self.prefix = prefix
        } else {
            return nil
        }
    }

    func overlaps(_ other: IPNetwork) -> Bool {
        guard family == other.family else { return false }
        let comparedBits = min(prefix, other.prefix)
        let fullBytes = comparedBits / 8
        guard bytes.prefix(fullBytes).elementsEqual(other.bytes.prefix(fullBytes)) else { return false }
        let remainingBits = comparedBits % 8
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << (8 - remainingBits)
        return bytes[fullBytes] & mask == other.bytes[fullBytes] & mask
    }

    func contains(_ other: IPNetwork) -> Bool {
        guard family == other.family, prefix <= other.prefix else { return false }
        let fullBytes = prefix / 8
        guard bytes.prefix(fullBytes).elementsEqual(other.bytes.prefix(fullBytes)) else { return false }
        let remainingBits = prefix % 8
        guard remainingBits > 0 else { return true }
        let mask = UInt8.max << (8 - remainingBits)
        return bytes[fullBytes] & mask == other.bytes[fullBytes] & mask
    }
}

public struct ForcedProxyRuleBatch: Sendable {
    public let rules: [CustomRouteRule]

    public init(
        domainInput: String,
        ipInput: String,
        existingRules: [CustomRouteRule],
        proxyGroup: String
    ) throws {
        var rules = existingRules
        var nextOrder = (rules.map(\.order).max() ?? -1) + 1

        let domains = Self.entries(in: domainInput)
        let cidrs = Self.entries(in: ipInput)
        for raw in domains {
            guard let value = CustomRouteRule.normalizedDomainSuffix(raw) else {
                throw RoutingValidationError.invalidForcedProxyDomain(raw)
            }
            guard value != "localhost", !value.hasSuffix(".localhost") else {
                throw RoutingValidationError.loopbackForcedProxy
            }
            rules.removeAll {
                $0.action == .proxy && $0.type == .domainSuffix
                    && $0.value.caseInsensitiveCompare(value) == .orderedSame
            }
            rules.append(CustomRouteRule(
                order: nextOrder,
                type: .domainSuffix,
                value: value,
                action: .proxy,
                proxyGroup: proxyGroup
            ))
            nextOrder += 1
        }
        for raw in cidrs {
            guard let value = CustomRouteRule.normalizedCIDR(raw) else {
                throw RoutingValidationError.invalidCIDR(raw)
            }
            guard !CustomRouteRule.isLoopbackCIDR(value) else {
                throw RoutingValidationError.loopbackForcedProxy
            }
            rules.removeAll {
                $0.action == .proxy && $0.type == .ipCIDR
                    && $0.value.caseInsensitiveCompare(value) == .orderedSame
            }
            rules.append(CustomRouteRule(
                order: nextOrder,
                type: .ipCIDR,
                value: value,
                action: .proxy,
                proxyGroup: proxyGroup
            ))
            nextOrder += 1
        }
        self.rules = rules
    }

    private static func entries(in input: String) -> [String] {
        input
            .components(separatedBy: CharacterSet(charactersIn: ",;\n\r\t "))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct RouteTestInput: Equatable, Sendable {
    public var domain: String?
    public var ip: String?
    public var processName: String?

    public init(domain: String? = nil, ip: String? = nil, processName: String? = nil) {
        self.domain = domain?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.ip = ip?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.processName = processName?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct RouteTestResult: Equatable, Sendable {
    public enum Source: String, Sendable {
        case custom = "用户规则"
        case bypass = "绕过列表"
        case subscription = "订阅规则"
        case privateNetwork = "私有网络"
        case final = "最终规则"
    }

    public let source: Source
    public let priority: Int
    public let action: RouteAction
    public let target: String
    public let matchedValue: String

    public init(source: Source, priority: Int, action: RouteAction, target: String, matchedValue: String) {
        self.source = source
        self.priority = priority
        self.action = action
        self.target = target
        self.matchedValue = matchedValue
    }
}

/// Evaluates all locally knowable route layers in the same order used by
/// ConfigGenerator.route. Geo rule-set contents remain sing-box-owned, so an
/// unmatched input is reported as the final proxy route instead of guessed.
public enum RouteRuleEvaluator {
    public static func evaluate(
        _ input: RouteTestInput,
        settings: RoutingSettings,
        subscriptionRules: [SubscriptionRule],
        primaryOutbound: String
    ) -> RouteTestResult {
        let custom = settings.customRules.filter(\.enabled).sorted { $0.order < $1.order }
        for (index, rule) in custom.enumerated() where matches(rule.type, value: rule.value, input: input) {
            return result(
                source: .custom,
                priority: index + 1,
                action: rule.action,
                target: rule.action == .proxy ? (rule.proxyGroup ?? primaryOutbound) : rule.action.displayName,
                value: rule.value
            )
        }

        let bypassPriority = custom.count + 1
        if let domain = input.domain,
           let value = settings.bypassDomains.first(where: { matchesDomainBypass($0, domain: domain) }) {
            return result(source: .bypass, priority: bypassPriority, action: .direct, target: "DIRECT", value: value)
        }
        if let ip = input.ip,
           let value = settings.bypassCIDRs.first(where: { CustomRouteRule.cidr($0, contains: ip) }) {
            return result(source: .bypass, priority: bypassPriority, action: .direct, target: "DIRECT", value: value)
        }

        if settings.useSubscriptionRules {
            for (index, rule) in subscriptionRules.enumerated()
                where matches(rule.type, value: rule.value, input: input) {
                let action: RouteAction = switch rule.target.uppercased() {
                case "DIRECT": .direct
                case "REJECT", "REJECT-DROP": .reject
                default: .proxy
                }
                return result(
                    source: .subscription,
                    priority: bypassPriority + index + 1,
                    action: action,
                    target: rule.target,
                    value: rule.value
                )
            }
        }

        if let ip = input.ip, Self.privateCIDRs.contains(where: { CustomRouteRule.cidr($0, contains: ip) }) {
            return result(
                source: .privateNetwork,
                priority: bypassPriority + subscriptionRules.count + 1,
                action: .direct,
                target: "DIRECT",
                value: "ip_is_private"
            )
        }
        return result(
            source: .final,
            priority: bypassPriority + subscriptionRules.count + 2,
            action: .proxy,
            target: primaryOutbound,
            value: "FINAL"
        )
    }

    private static let privateCIDRs = [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8",
        "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"
    ]

    private static func result(
        source: RouteTestResult.Source,
        priority: Int,
        action: RouteAction,
        target: String,
        value: String
    ) -> RouteTestResult {
        RouteTestResult(source: source, priority: priority, action: action, target: target, matchedValue: value)
    }

    private static func matches(_ type: CustomRuleType, value: String, input: RouteTestInput) -> Bool {
        switch type {
        case .domainSuffix:
            guard let domain = input.domain else { return false }
            let suffix = value.lowercased()
            return domain == suffix || domain.hasSuffix(".\(suffix)")
        case .domainKeyword:
            return input.domain?.localizedCaseInsensitiveContains(value) == true
        case .domain:
            return input.domain?.caseInsensitiveCompare(value) == .orderedSame
        case .ipCIDR:
            return input.ip.map { CustomRouteRule.cidr(value, contains: $0) } == true
        case .processName:
            return input.processName?.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    private static func matchesDomainBypass(_ raw: String, domain: String) -> Bool {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("*.") { value.removeFirst(2) }
        if value.hasPrefix(".") { value.removeFirst() }
        return domain == value || domain.hasSuffix(".\(value)")
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
    /// 使用 OpenSSH ProxyCommand 送入本地 mixed 入口的精确 IP。
    /// 与 customRules 分开，避免把“仅 SSH”误表达为整个 IP 的 TUN 流量规则。
    public var sshProxyTargets: [SSHProxyTarget]
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
        sshProxyTargets: [SSHProxyTarget] = [],
        blockAds: Bool
    ) {
        self.policyGroups = policyGroups
        self.customRules = customRules
        self.sshProxyTargets = sshProxyTargets
        self.bypassDomains = bypassDomains
        self.bypassCIDRs = bypassCIDRs
        self.tunExcludeCIDRs = tunExcludeCIDRs
        self.blockAds = blockAds
    }

    /// 旧版设置文件没有该字段，解码时回落到默认私有网段，避免升级后 TUN 排除列表变空。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        customRules = try container.decode([CustomRouteRule].self, forKey: .customRules)
        sshProxyTargets = try container.decodeIfPresent([SSHProxyTarget].self, forKey: .sshProxyTargets) ?? []
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

    /// 回环必须始终在系统代理绕过表里：App 自己要用 `127.0.0.1:<clashPort>` 访问内核控制接口，
    /// 用户若把默认的 localhost/127.0.0.0/8 从绕过列表里删掉，这些请求会绕回内核形成自指，
    /// 仪表盘/日志/测速全部异常。这里无条件补上，用户的自定义项照常保留。
    public static let mandatoryProxyBypass = ["127.0.0.1", "localhost", "::1"]

    public var systemProxyBypassEntries: [String] {
        systemProxyBypassEntries(including: [])
    }

    /// 强制代理规则必须先让流量进入内核。与规则冲突的 macOS bypass 项会在运行时省略；
    /// 回环三项始终保留，避免 App 的控制接口请求绕回代理形成自指。
    public func systemProxyBypassEntries(
        including additionalDomains: [String],
        respectingForcedProxyRules: Bool = true
    ) -> [String] {
        let allDomains = bypassDomains + additionalDomains
        let domains = respectingForcedProxyRules
            ? allDomains.filter { !conflictsWithForcedProxy(domainBypass: $0) }
            : allDomains
        let cidrs = respectingForcedProxyRules
            ? bypassCIDRs.filter { !conflictsWithForcedProxy(cidr: $0) }
            : bypassCIDRs
        var seen = Set<String>()
        return (Self.mandatoryProxyBypass + domains + cidrs)
            .filter { seen.insert($0).inserted }
    }

    /// TUN 的 route exclude 在 sing-box 路由规则之前生效；冲突网段若留在这里，
    /// “强制代理”规则永远收不到该流量。回环排除仍不可移除。
    public var effectiveTunExcludeCIDRs: [String] {
        tunExcludeCIDRs.filter { cidr in
            CustomRouteRule.isLoopbackCIDR(cidr) || !conflictsWithForcedProxy(cidr: cidr)
        }
    }

    private var enabledForcedProxyRules: [CustomRouteRule] {
        customRules.filter { $0.enabled && $0.action == .proxy }
    }

    private func conflictsWithForcedProxy(domainBypass entry: String) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isSuffix = trimmed.hasPrefix("*.") || trimmed.hasPrefix(".")
        let bypass = trimmed.hasPrefix("*.") ? String(trimmed.dropFirst(2))
            : trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        guard !bypass.isEmpty else { return false }

        return enabledForcedProxyRules.contains { rule in
            guard rule.type == .domain || rule.type == .domainSuffix,
                  let forced = CustomRouteRule.normalizedDomainSuffix(rule.value) else { return false }
            switch rule.type {
            case .domain:
                return forced == bypass || (isSuffix && forced.hasSuffix(".\(bypass)"))
            case .domainSuffix:
                if isSuffix {
                    return forced == bypass
                        || forced.hasSuffix(".\(bypass)")
                        || bypass.hasSuffix(".\(forced)")
                }
                return bypass == forced || bypass.hasSuffix(".\(forced)")
            default:
                return false
            }
        }
    }

    private func conflictsWithForcedProxy(cidr: String) -> Bool {
        guard let bypass = IPNetwork(CustomRouteRule.normalizedCIDR(cidr) ?? cidr) else { return false }
        return enabledForcedProxyRules.contains { rule in
            guard rule.type == .ipCIDR,
                  let forcedValue = CustomRouteRule.normalizedCIDR(rule.value),
                  let forced = IPNetwork(forcedValue) else { return false }
            return bypass.overlaps(forced)
        }
    }

    public func validated() throws -> RoutingSettings {
        var settings = self
        settings.policyGroups = try policyGroups.map { try $0.validated() }
        let names = settings.policyGroups.map(\.name)
        guard Set(names).count == names.count else {
            throw RoutingValidationError.duplicatePolicyGroupName
        }
        settings.customRules = try customRules.map { try $0.validated() }.sorted { $0.order < $1.order }
        settings.sshProxyTargets = try sshProxyTargets.map { try $0.validated() }
        var seenSSHTargets = Set<SSHProxyTarget>()
        settings.sshProxyTargets = settings.sshProxyTargets.filter { seenSSHTargets.insert($0).inserted }
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
    case invalidForcedProxyDomain(String)
    case loopbackForcedProxy
    case unsupportedForcedProxyRuleType
    case invalidSSHProxyAddress(String)
    case invalidSSHProxyPort(Int)
    case missingProxyGroup
    case emptyBypassDomain

    public var errorDescription: String? {
        switch self {
        case .emptyRuleValue: "规则匹配值不能为空"
        case let .invalidCIDR(value): "IP CIDR 无效：\(value)"
        case let .invalidForcedProxyDomain(value): "域名无效：\(value)。请输入域名，不要包含协议、端口或路径"
        case .loopbackForcedProxy: "回环地址必须保持直连，以免代理控制接口形成自指"
        case .unsupportedForcedProxyRuleType: "强制代理仅支持域名或 IP / CIDR"
        case let .invalidSSHProxyAddress(value): "SSH 代理目标必须是单个 IPv4 或 IPv6 地址：\(value)"
        case let .invalidSSHProxyPort(port): "SSH 端口无效：\(port)"
        case .missingProxyGroup: "代理规则必须选择策略组"
        case .emptyBypassDomain: "绕过域名不能为空"
        case .emptyPolicyGroupName: "策略组名称不能为空"
        case let .reservedPolicyGroupName(name): "「\(name)」是内置策略组名，请换一个"
        case .duplicatePolicyGroupName: "策略组名称不能重复"
        case let .invalidPolicyGroupName(name): "策略组名「\(name)」含有不支持的字符或过长（上限 40）"
        }
    }
}
