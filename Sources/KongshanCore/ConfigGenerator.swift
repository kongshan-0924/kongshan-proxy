import Foundation

public struct PreparedRuleSets: Equatable, Sendable {
    public let geositeCN: URL
    public let geoipCN: URL
    public let ads: URL?

    public init(geositeCN: URL, geoipCN: URL, ads: URL?) {
        self.geositeCN = geositeCN
        self.geoipCN = geoipCN
        self.ads = ads
    }
}

public struct RoutingConfiguration: Equatable, Sendable {
    public let settings: RoutingSettings
    public let ruleSets: PreparedRuleSets
    /// 订阅自带的分流规则，按顺序排在用户规则与绕过之后。
    public let subscriptionRules: [SubscriptionRule]

    public init(
        settings: RoutingSettings,
        ruleSets: PreparedRuleSets,
        subscriptionRules: [SubscriptionRule] = []
    ) {
        self.settings = settings
        self.ruleSets = ruleSets
        self.subscriptionRules = subscriptionRules
    }
}

public struct ConfigInput: Sendable {
    public let nodes: [ProxyNode]
    public let selectedNodeID: UUID?
    public let runtime: RuntimeParameters
    public let testURL: String
    public let routing: RoutingConfiguration?
    /// 生效的接管方式，可同时包含系统代理与 TUN。
    public let enabledModes: Set<ProxyMode>
    public let outboundMode: OutboundMode
    public let tunSettings: TunSettings
    public let dnsSettings: DNSSettings
    /// 各策略组重启后要恢复的选中出站（组名 → 出站 tag）。
    /// 内核不落盘选择状态，不带上它们的话每次重启按服务分组全部回退。
    public let groupDefaults: [String: String]

    public var usesSystemProxy: Bool { enabledModes.contains(.systemProxy) }
    public var usesTun: Bool { enabledModes.contains(.tun) }

    public init(
        nodes: [ProxyNode],
        selectedNodeID: UUID?,
        runtime: RuntimeParameters,
        testURL: String = "http://www.gstatic.com/generate_204",
        routing: RoutingConfiguration? = nil,
        enabledModes: Set<ProxyMode> = [.systemProxy],
        outboundMode: OutboundMode = .rule,
        tunSettings: TunSettings = .defaults,
        dnsSettings: DNSSettings = .defaults,
        groupDefaults: [String: String] = [:]
    ) {
        self.outboundMode = outboundMode
        self.nodes = nodes
        self.selectedNodeID = selectedNodeID
        self.runtime = runtime
        self.testURL = testURL
        self.routing = routing
        self.enabledModes = enabledModes.isEmpty ? [.systemProxy] : enabledModes
        self.tunSettings = tunSettings
        self.dnsSettings = dnsSettings
        self.groupDefaults = groupDefaults
    }

    /// 单一模式的便捷入口。
    public init(
        nodes: [ProxyNode],
        selectedNodeID: UUID?,
        runtime: RuntimeParameters,
        testURL: String = "http://www.gstatic.com/generate_204",
        routing: RoutingConfiguration? = nil,
        proxyMode: ProxyMode,
        outboundMode: OutboundMode = .rule,
        tunSettings: TunSettings = .defaults,
        dnsSettings: DNSSettings = .defaults
    ) {
        self.init(
            nodes: nodes,
            selectedNodeID: selectedNodeID,
            runtime: runtime,
            testURL: testURL,
            routing: routing,
            enabledModes: [proxyMode],
            outboundMode: outboundMode,
            tunSettings: tunSettings,
            dnsSettings: dnsSettings
        )
    }
}

public enum ConfigGenerationError: Error, Equatable, LocalizedError {
    case noNodes
    case selectedNodeMissing
    case missingField(node: String, field: String)
    case missingRuleSet(String)
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .noNodes: "至少需要一个代理节点"
        case .selectedNodeMissing: "当前选中的节点已不存在"
        case let .missingField(node, field): "节点 \(node) 缺少 \(field)"
        case let .missingRuleSet(tag): "缺少规则集：\(tag)"
        case .invalidJSON: "生成的 sing-box 配置不是有效 JSON"
        }
    }
}

public enum ConfigGenerator {
    public static func outboundTag(for node: ProxyNode) -> String {
        "node-\(node.id.uuidString.lowercased())"
    }

    public static func generate(_ input: ConfigInput) throws -> Data {
        guard !input.nodes.isEmpty else { throw ConfigGenerationError.noNodes }

        let nodeTags = input.nodes.map(outboundTag)
        let selectedTag: String
        if let selectedNodeID = input.selectedNodeID {
            guard let selected = input.nodes.first(where: { $0.id == selectedNodeID }) else {
                throw ConfigGenerationError.selectedNodeMissing
            }
            selectedTag = outboundTag(for: selected)
        } else {
            selectedTag = nodeTags[0]
        }

        var outbounds = try input.nodes.map(outbound)
        outbounds.append([
            "type": "selector",
            "tag": "手动选择",
            "outbounds": nodeTags,
            "default": selectedTag
        ])
        outbounds.append([
            "type": "urltest",
            "tag": "自动选择",
            "outbounds": nodeTags,
            "url": input.testURL,
            "interval": "5m"
        ])

        // 策略组：配置自带的组（Netflix / 香港 …）或用户自建组。每组一个出站，
        // 分流规则可指向它，托盘/代理页也能单独为它选节点（对应 Stash 的按策略分流）。
        let groups = (try? input.routing?.settings.validated().policyGroups) ?? []
        let nodeNameToTag = Dictionary(
            input.nodes.map { ($0.name, outboundTag(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let groupNames = Set(groups.map(\.name)).union(["手动选择", "自动选择", "自建"])

        // 机场常见"轮辐"结构：一个主组(如 TAGSS)汇聚全部节点、其它代理策略默认指向它，
        // 而主组自身默认走"绕过代理"(直连) → 开了代理却全走直连、"手动选择"选的节点也不生效。
        // 处理：只把这个主组默认接到"手动选择"，指向主组的策略(国外媒体→主组、兜底→主组)自然跟随，
        // 用户在"手动选择"挑一次节点即可贯穿所有需代理的流量；地区子组/直连/拒绝组与显式选择都不动。
        func wrapperKind(_ g: PolicyGroup) -> String? {
            let ms = g.members.map { $0.uppercased() }
            guard !ms.isEmpty else { return nil }
            if ms.allSatisfy({ $0 == "DIRECT" }) { return "direct" }
            if ms.allSatisfy({ $0 == "REJECT" || $0 == "REJECT-DROP" }) { return "reject" }
            return nil
        }
        let proxyGroupNames = Set(groups.filter { wrapperKind($0) == nil }.map(\.name))
        // 主组 = 被 ≥2 个其它组当作"首个成员(默认)"引用、且自身是代理组的那个。≥2 把汇聚型主组
        // 与只被引用一次的地区子组(香港/日本)区分开，避免误改地区组。
        // ponytail: 轮辐结构的启发式；层级式(主组在根、被引用 0 次)配置识别不到主组，此时仅
        //           final 走手动选择、代理仍可用，可日后按需增强。
        var firstMemberRefs: [String: Int] = [:]
        for g in groups { if let first = g.members.first { firstMemberRefs[first, default: 0] += 1 } }
        let masterGroup = firstMemberRefs
            .filter { proxyGroupNames.contains($0.key) && $0.value >= 2 }
            .max { $0.value < $1.value }?.key

        for group in groups {
            // 成员名解析成出站 tag；解析不到的丢弃，全丢光则回退到全部节点，
            // 避免生成空组导致 sing-box 校验失败、内核起不来。
            var members = group.members.compactMap { member -> String? in
                switch member.uppercased() {
                case "DIRECT": return "direct"
                case "REJECT", "REJECT-DROP": return "reject"
                default:
                    if let tag = nodeNameToTag[member] { return tag }
                    return groupNames.contains(member) ? member : nil
                }
            }
            if members.isEmpty { members = nodeTags }
            switch group.kind {
            case .selector:
                // 优先恢复该组自己记住的节点；不在成员里则回退。
                let remembered = input.groupDefaults[group.name].flatMap { members.contains($0) ? $0 : nil }
                var mem = members
                let def: String
                if group.name == masterGroup {
                    // 主组默认接到"手动选择"：用户在"手动选择"挑一次节点，即可贯穿所有默认
                    // 指向主组的策略与规则(国外媒体→主组、兜底→主组…)。
                    if !mem.contains("手动选择") { mem.insert("手动选择", at: 0) }
                    def = "手动选择"
                } else {
                    def = remembered ?? members[0]
                }
                outbounds.append([
                    "type": "selector",
                    "tag": group.name,
                    "outbounds": mem,
                    "default": def
                ])
            case .urltest:
                outbounds.append([
                    "type": "urltest",
                    "tag": group.name,
                    "outbounds": members,
                    "url": input.testURL,
                    "interval": "5m"
                ])
            }
        }

        let manualTags = input.nodes.filter { $0.sourceID == nil }.map(outboundTag)
        if !manualTags.isEmpty {
            let remembered = input.groupDefaults["自建"]
                .flatMap { manualTags.contains($0) ? $0 : nil }
            outbounds.append([
                "type": "selector",
                "tag": "自建",
                "outbounds": manualTags,
                "default": remembered ?? manualTags[0]
            ])
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "reject"])

        var route = try route(for: input.routing, outboundMode: input.outboundMode)
        route["default_domain_resolver"] = "dns-cn"
        var prefixRules: [[String: Any]] = []
        if input.outboundMode == .rule {
            // SOCKS 客户端可能只送 IP 过来；不嗅探的话域名规则整条落空，
            // 全靠 geoip 兜底。TUN 之外的 mixed 入站同样受益。
            prefixRules.append(["action": "sniff"])
        }
        if input.usesTun {
            route["auto_detect_interface"] = true
            prefixRules.append(["protocol": "dns", "action": "hijack-dns"])
        }
        if !prefixRules.isEmpty {
            var rules = route["rules"] as? [[String: Any]] ?? []
            rules.insert(contentsOf: prefixRules, at: 0)
            route["rules"] = rules
        }

        let root: [String: Any] = [
            "log": ["level": "info", "timestamp": true],
            "dns": try dns(for: input),
            "inbounds": try inbounds(for: input),
            "outbounds": outbounds,
            "route": route,
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:\(input.runtime.clashPort)",
                    "secret": input.runtime.secret
                ]
            ]
        ]
        return try encode(root)
    }

    private static func dns(for input: ConfigInput) throws -> [String: Any] {
        let endpoints = try input.dnsSettings.endpoints()
        var servers: [[String: Any]] = []

        if !endpoints.domestic.hostIsIPAddress {
            servers.append([
                "type": "udp",
                "tag": "dns-bootstrap",
                "server": "223.5.5.5",
                "server_port": 53
            ])
        }

        var domestic = dohServer(
            endpoint: endpoints.domestic,
            tag: "dns-cn",
            detour: nil
        )
        if !endpoints.domestic.hostIsIPAddress {
            domestic["domain_resolver"] = "dns-bootstrap"
        }
        servers.append(domestic)

        var remote = dohServer(
            endpoint: endpoints.remote,
            tag: "dns-remote",
            detour: "手动选择"
        )
        if !endpoints.remote.hostIsIPAddress {
            remote["domain_resolver"] = "dns-cn"
        }
        servers.append(remote)

        var rules: [[String: Any]] = []
        if input.routing != nil, input.outboundMode == .rule {
            rules.append([
                "rule_set": "geosite-cn",
                "action": "route",
                "server": "dns-cn"
            ])
        }
        return [
            "servers": servers,
            "rules": rules,
            // 直连模式不应把解析绕到代理出口
            "final": input.outboundMode == .direct ? "dns-cn" : "dns-remote"
        ]
    }

    private static func dohServer(
        endpoint: DoHEndpoint,
        tag: String,
        detour: String?
    ) -> [String: Any] {
        var server: [String: Any] = [
            "type": "https",
            "tag": tag,
            "server": endpoint.host,
            "path": endpoint.path,
            "tls": [
                "enabled": true,
                "server_name": endpoint.host
            ]
        ]
        if let detour { server["detour"] = detour }
        if let port = endpoint.port, port != 443 {
            server["server_port"] = port
        }
        return server
    }

    /// 两种接管方式可同时开启，此时同一个内核进程同时监听 mixed 与 tun。
    private static func inbounds(for input: ConfigInput) throws -> [[String: Any]] {
        var result: [[String: Any]] = []

        if input.usesSystemProxy {
            result.append([
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": Int(input.runtime.mixedPort)
            ])
        }

        if input.usesTun {
            // macOS 的 utun 名字必须是 utunN，自定义名（如 kongshan-tun）会被内核拒绝
            // （bad tun name）。不写 interface_name，交给 sing-box 自动分配 utunN。
            var inbound: [String: Any] = [
                "type": "tun",
                "tag": "tun-in",
                "address": input.tunSettings.addresses,
                "mtu": input.tunSettings.mtu,
                "auto_route": true,
                "strict_route": input.tunSettings.strictRoute,
                "stack": input.tunSettings.stack.rawValue
            ]
            if let routing = input.routing {
                inbound["route_exclude_address"] = try routing.settings.validated().tunExcludeCIDRs
            }
            result.append(inbound)
        }

        return result
    }

    /// Clash 的 DIRECT/REJECT 与策略组名映射到我们生成的出站；无法解析的规则直接丢弃。
    private static func resolvedOutbound(for target: String, available: Set<String>) -> String? {
        switch target.uppercased() {
        case "DIRECT": return "direct"
        case "REJECT", "REJECT-DROP": return "reject"
        default: return available.contains(target) ? target : nil
        }
    }

    /// 把订阅规则按「连续的同类型、同出站」合并成一条（多个值放进同一数组）。
    /// 机场动辄几千条独立规则会让配置膨胀到 1MB+，拖慢生成/编码/内核解析，界面也会卡。
    /// 合并后通常只剩一两百条；语义不变——单条规则里同一字段的多值是「或」，等价于多条连续规则；
    /// 只合并「连续」段，因此匹配顺序（首个命中生效）与合并前完全一致。
    static func mergedSubscriptionRules(
        _ subscriptionRules: [SubscriptionRule],
        available: Set<String>
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var field: String?
        var outbound: String?
        var values: [String] = []

        func flush() {
            if let field, let outbound, !values.isEmpty {
                result.append([field: values, "action": "route", "outbound": outbound])
            }
            values = []
        }

        for rule in subscriptionRules {
            guard let target = resolvedOutbound(for: rule.target, available: available) else { continue }
            let ruleField = ruleField(for: rule.type)
            if ruleField == field, target == outbound {
                values.append(rule.value)
            } else {
                flush()
                field = ruleField
                outbound = target
                values = [rule.value]
            }
        }
        flush()
        return result
    }

    private static func route(
        for routing: RoutingConfiguration?,
        outboundMode: OutboundMode = .rule
    ) throws -> [String: Any] {
        // 全局 / 直连不参与分流：不加载任何规则集，直接给一个兜底出口。
        switch outboundMode {
        case .global:
            return ["rules": [], "final": "手动选择"]
        case .direct:
            return ["rules": [], "final": "direct"]
        case .rule:
            break
        }

        guard let routing else {
            return ["rules": [], "final": "手动选择"]
        }

        let settings = try routing.settings.validated()
        var rules = settings.customRules
            .filter(\.enabled)
            .map(customRouteRule)

        if let bypass = bypassRule(for: settings) {
            rules.append(bypass)
        }

        // 订阅自带规则：优先级低于用户规则与绕过，高于内置的私有网段/中国直连。
        // 目标必须能解析到已存在的出站，否则内核校验会失败，因此逐条过滤。
        if settings.useSubscriptionRules {
            let available = Set(
                ["direct", "reject", "手动选择", "自动选择", "自建"] + settings.policyGroups.map(\.name)
            )
            rules.append(contentsOf: mergedSubscriptionRules(routing.subscriptionRules, available: available))
        }
        rules.append([
            "ip_is_private": true,
            "action": "route",
            "outbound": "direct"
        ])

        var ruleSets = [
            localRuleSet(tag: "geosite-cn", path: routing.ruleSets.geositeCN),
            localRuleSet(tag: "geoip-cn", path: routing.ruleSets.geoipCN)
        ]
        if settings.blockAds {
            guard let ads = routing.ruleSets.ads else {
                throw ConfigGenerationError.missingRuleSet("geosite-category-ads-all")
            }
            rules.append([
                "rule_set": "geosite-category-ads-all",
                "action": "route",
                "outbound": "reject"
            ])
            ruleSets.append(localRuleSet(tag: "geosite-category-ads-all", path: ads))
        }

        rules.append([
            "rule_set": ["geosite-cn", "geoip-cn"],
            "action": "route",
            "outbound": "direct"
        ])

        return [
            "rules": rules,
            "rule_set": ruleSets,
            "final": "手动选择"
        ]
    }

    static func ruleField(for type: CustomRuleType) -> String {
        switch type {
        case .domainSuffix: "domain_suffix"
        case .domainKeyword: "domain_keyword"
        case .domain: "domain"
        case .ipCIDR: "ip_cidr"
        case .processName: "process_name"
        }
    }

    private static func customRouteRule(_ rule: CustomRouteRule) -> [String: Any] {
        let field = ruleField(for: rule.type)

        let outbound: String
        switch rule.action {
        case .direct: outbound = "direct"
        case .proxy: outbound = rule.proxyGroup ?? "自动选择"
        case .reject: outbound = "reject"
        }
        return [field: [rule.value], "action": "route", "outbound": outbound]
    }

    private static func bypassRule(for settings: RoutingSettings) -> [String: Any]? {
        var exactDomains: [String] = []
        var domainSuffixes: [String] = []
        for domain in settings.bypassDomains {
            if domain.hasPrefix("*.") {
                domainSuffixes.append(String(domain.dropFirst(2)))
            } else if domain.hasPrefix(".") {
                domainSuffixes.append(String(domain.dropFirst()))
            } else {
                exactDomains.append(domain)
            }
        }

        var rule: [String: Any] = ["action": "route", "outbound": "direct"]
        if !exactDomains.isEmpty { rule["domain"] = exactDomains }
        if !domainSuffixes.isEmpty { rule["domain_suffix"] = domainSuffixes }
        if !settings.bypassCIDRs.isEmpty { rule["ip_cidr"] = settings.bypassCIDRs }
        return rule.count > 2 ? rule : nil
    }

    private static func localRuleSet(tag: String, path: URL) -> [String: Any] {
        ["type": "local", "tag": tag, "format": "binary", "path": path.path]
    }

    public static func diagnosticSnapshot(from fullConfig: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: fullConfig) as? [String: Any] else {
            throw ConfigGenerationError.invalidJSON
        }
        if var experimental = root["experimental"] as? [String: Any] {
            experimental.removeValue(forKey: "clash_api")
            if experimental.isEmpty {
                root.removeValue(forKey: "experimental")
            } else {
                root["experimental"] = experimental
            }
        }
        return try encode(root)
    }

    private static func outbound(_ node: ProxyNode) throws -> [String: Any] {
        var value: [String: Any] = [
            "type": node.protocolType.rawValue,
            "tag": outboundTag(for: node),
            "server": node.server,
            "server_port": node.port
        ]

        switch node.protocolType {
        case .shadowsocks:
            value["method"] = try required(node.method, node: node, field: "method")
            value["password"] = try required(node.password, node: node, field: "password")
        case .trojan:
            value["password"] = try required(node.password, node: node, field: "password")
            value["tls"] = tls(for: node)
            if let transport = transport(node.transport) { value["transport"] = transport }
        case .vmess:
            value["uuid"] = try required(node.uuid, node: node, field: "uuid")
            value["security"] = node.security ?? "auto"
            value["alter_id"] = node.alterID ?? 0
            if node.tlsEnabled { value["tls"] = tls(for: node) }
            if let transport = transport(node.transport) { value["transport"] = transport }
        case .hysteria2:
            value["password"] = try required(node.password, node: node, field: "password")
            value["tls"] = tls(for: node)
            if let uploadMbps = node.uploadMbps { value["up_mbps"] = uploadMbps }
            if let downloadMbps = node.downloadMbps { value["down_mbps"] = downloadMbps }
            if let obfsPassword = node.obfsPassword {
                value["obfs"] = ["type": "salamander", "password": obfsPassword]
            }
        case .anytls:
            value["password"] = try required(node.password, node: node, field: "password")
            value["tls"] = tls(for: node)
        }
        return value
    }

    private static func required(_ value: String?, node: ProxyNode, field: String) throws -> String {
        guard let value, !value.isEmpty else {
            throw ConfigGenerationError.missingField(node: node.name, field: field)
        }
        return value
    }

    private static func tls(for node: ProxyNode) -> [String: Any] {
        [
            "enabled": true,
            "server_name": node.sni ?? node.server,
            "insecure": node.skipCertificateVerification
        ]
    }

    private static func transport(_ options: TransportOptions?) -> [String: Any]? {
        guard let options else { return nil }
        switch options.kind {
        case .websocket:
            var value: [String: Any] = ["type": "ws"]
            if let path = options.path { value["path"] = path }
            if !options.headers.isEmpty { value["headers"] = options.headers }
            return value
        case .grpc:
            var value: [String: Any] = ["type": "grpc"]
            if let serviceName = options.serviceName { value["service_name"] = serviceName }
            return value
        }
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw ConfigGenerationError.invalidJSON }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
