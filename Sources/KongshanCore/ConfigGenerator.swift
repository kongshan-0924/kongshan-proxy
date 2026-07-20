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

    public init(settings: RoutingSettings, ruleSets: PreparedRuleSets) {
        self.settings = settings
        self.ruleSets = ruleSets
    }
}

public struct ConfigInput: Sendable {
    public let nodes: [ProxyNode]
    public let selectedNodeID: UUID?
    public let runtime: RuntimeParameters
    public let testURL: String
    public let routing: RoutingConfiguration?
    public let proxyMode: ProxyMode
    public let tunSettings: TunSettings
    public let dnsSettings: DNSSettings

    public init(
        nodes: [ProxyNode],
        selectedNodeID: UUID?,
        runtime: RuntimeParameters,
        testURL: String = "http://www.gstatic.com/generate_204",
        routing: RoutingConfiguration? = nil,
        proxyMode: ProxyMode = .systemProxy,
        tunSettings: TunSettings = .defaults,
        dnsSettings: DNSSettings = .defaults
    ) {
        self.nodes = nodes
        self.selectedNodeID = selectedNodeID
        self.runtime = runtime
        self.testURL = testURL
        self.routing = routing
        self.proxyMode = proxyMode
        self.tunSettings = tunSettings
        self.dnsSettings = dnsSettings
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

        let manualTags = input.nodes.filter { $0.sourceID == nil }.map(outboundTag)
        if !manualTags.isEmpty {
            outbounds.append([
                "type": "selector",
                "tag": "自建",
                "outbounds": manualTags,
                "default": manualTags[0]
            ])
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "reject"])

        var route = try route(for: input.routing)
        route["default_domain_resolver"] = "dns-cn"
        if input.proxyMode == .tun {
            route["auto_detect_interface"] = true
            var rules = route["rules"] as? [[String: Any]] ?? []
            rules.insert(contentsOf: [
                ["action": "sniff"],
                ["protocol": "dns", "action": "hijack-dns"]
            ], at: 0)
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
            detour: "自动选择"
        )
        if !endpoints.remote.hostIsIPAddress {
            remote["domain_resolver"] = "dns-cn"
        }
        servers.append(remote)

        var rules: [[String: Any]] = []
        if input.routing != nil {
            rules.append([
                "rule_set": "geosite-cn",
                "action": "route",
                "server": "dns-cn"
            ])
        }
        return [
            "servers": servers,
            "rules": rules,
            "final": "dns-remote"
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

    private static func inbounds(for input: ConfigInput) throws -> [[String: Any]] {
        switch input.proxyMode {
        case .systemProxy:
            return [[
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": Int(input.runtime.mixedPort)
            ]]
        case .tun:
            var inbound: [String: Any] = [
                "type": "tun",
                "tag": "tun-in",
                "interface_name": input.tunSettings.interfaceName,
                "address": input.tunSettings.addresses,
                "mtu": input.tunSettings.mtu,
                "auto_route": true,
                "strict_route": input.tunSettings.strictRoute,
                "stack": "system"
            ]
            if let routing = input.routing {
                inbound["route_exclude_address"] = try routing.settings.validated().bypassCIDRs
            }
            return [inbound]
        }
    }

    private static func route(for routing: RoutingConfiguration?) throws -> [String: Any] {
        guard let routing else {
            return ["rules": [], "final": "自动选择"]
        }

        let settings = try routing.settings.validated()
        var rules = settings.customRules
            .filter(\.enabled)
            .map(customRouteRule)

        if let bypass = bypassRule(for: settings) {
            rules.append(bypass)
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
            "final": "自动选择"
        ]
    }

    private static func customRouteRule(_ rule: CustomRouteRule) -> [String: Any] {
        let field: String
        switch rule.type {
        case .domainSuffix: field = "domain_suffix"
        case .domainKeyword: field = "domain_keyword"
        case .domain: field = "domain"
        case .ipCIDR: field = "ip_cidr"
        case .processName: field = "process_name"
        }

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
