import CryptoKit
import Foundation
@preconcurrency import Yams

public struct SubscriptionConversionResult: Sendable {
    /// 订阅自带的策略组（Clash 的 `proxy-groups`），可直接导入使用。
    public var policyGroups: [PolicyGroup] = []
    /// 订阅自带的分流规则（按订阅原顺序），已过滤掉不支持的类型。
    /// 含单条规则、`RULE-SET` 引用与 `GEOIP`；`RULE-SET` 只保留 `ruleProviders` 里存在的那些。
    public var subscriptionRules: [SubscriptionRule] = []
    /// 订阅的 `rule-providers`：被 `RULE-SET` 引用、且形态受支持的规则集。
    public var ruleProviders: [SubscriptionRuleProvider] = []
    /// `MATCH,<目标>` 的目标，即订阅指定的兜底出口（如「🐟 漏网之鱼」）；没写 MATCH 为 nil。
    public var matchTarget: String?
    public let nodes: [ProxyNode]
    public let warnings: [String]

    public init(nodes: [ProxyNode], warnings: [String],
        policyGroups: [PolicyGroup] = [],
        subscriptionRules: [SubscriptionRule] = [],
        ruleProviders: [SubscriptionRuleProvider] = [],
        matchTarget: String? = nil
    ) {
        self.nodes = nodes
        self.warnings = warnings
        self.policyGroups = policyGroups
        self.subscriptionRules = subscriptionRules
        self.ruleProviders = ruleProviders
        self.matchTarget = matchTarget
    }
}

public enum SubscriptionConversionError: Error, Equatable, LocalizedError {
    case missingProxies
    case noSupportedNodes
    /// 文档体积超上限。
    case documentTooLarge(bytes: Int, limit: Int)
    /// YAML 别名引用过多——见 `SubscriptionInputLimits.aliasReferenceLimit` 的说明。
    case tooManyAliasReferences(count: Int, limit: Int)
    /// 节点或规则条数超上限。
    case tooManyEntries(kind: String, count: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .missingProxies: "订阅中缺少 proxies 列表"
        case .noSupportedNodes: "订阅中没有可用的受支持节点"
        case let .documentTooLarge(bytes, limit):
            "订阅文档 \(bytes / 1024) KB，超过 \(limit / 1024) KB 上限，已拒绝解析"
        case let .tooManyAliasReferences(count, limit):
            "订阅使用了 \(count) 处 YAML 别名引用（上限 \(limit)）。"
                + "别名会在解析时成倍展开，正常机场订阅不会用到；已拒绝解析"
        case let .tooManyEntries(kind, count, limit):
            "订阅含 \(count) 条\(kind)，超过 \(limit) 条上限，已拒绝解析"
        }
    }
}

public enum ClashSubscriptionConverter {
    /// 解析 Clash 的 `proxy-groups`。名称与内置组冲突或非法的直接跳过，
    /// 不因为订阅里的一个坏分组而影响整体导入。
    static func policyGroups(from root: [String: Any]) -> [PolicyGroup] {
        guard let raw = root["proxy-groups"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var groups: [PolicyGroup] = []
        for entry in raw {
            guard let name = entry["name"] as? String else { continue }
            let kind: PolicyGroup.Kind = switch (entry["type"] as? String)?.lowercased() {
            case "url-test", "fallback", "load-balance": .urltest
            default: .selector
            }
            // 保留组的成员（节点名 / 其他组名 / DIRECT / REJECT），供代理页按策略展示、
            // 生成时解析成对应出站。用 `use:`（proxy-provider）的组没有显式成员，留空＝全部节点。
            let members = (entry["proxies"] as? [String]) ?? []
            guard var group = try? PolicyGroup(name: name, kind: kind).validated(),
                  !seen.contains(group.name) else { continue }
            group.members = members
            seen.insert(group.name)
            groups.append(group)
        }
        return groups
    }

    /// 解析 Clash 的 `rules:`，保持订阅原顺序（首个命中生效，顺序就是语义）。
    /// 含单条规则、`RULE-SET` 与 `GEOIP`；`MATCH` 另由 `matchTarget(from:)` 取出。
    static func subscriptionRules(from root: [String: Any]) -> [SubscriptionRule] {
        guard let raw = root["rules"] as? [String] else { return [] }
        var seen = Set<String>()
        var rules: [SubscriptionRule] = []
        for line in raw {
            guard let rule = SubscriptionRule.parse(line), !seen.contains(rule.id) else { continue }
            seen.insert(rule.id)
            rules.append(rule)
        }
        return rules
    }

    /// `MATCH,<目标>` 的目标。Clash 里 MATCH 是最后一条、兜住一切，取第一个出现的。
    static func matchTarget(from root: [String: Any]) -> String? {
        (root["rules"] as? [String])?.lazy.compactMap(SubscriptionRule.parseMatch).first
    }

    /// 解析 `rule-providers`。返回受支持的规则集与不支持项的说明（逐条，供告警）。
    static func ruleProviders(from root: [String: Any]) -> (providers: [SubscriptionRuleProvider], unsupported: [String]) {
        guard let raw = root["rule-providers"] as? [String: Any] else { return ([], []) }
        var providers: [SubscriptionRuleProvider] = []
        var unsupported: [String] = []
        // 字典无序；按名称排序，保证同一份订阅每次解析出的顺序一致（下载、缓存与界面都依赖它稳定）。
        for name in raw.keys.sorted() {
            guard let entry = raw[name] as? [String: Any] else {
                unsupported.append("\(name)：格式无法识别")
                continue
            }
            let parsed = SubscriptionRuleProvider.parse(name: name, entry: entry)
            if let provider = parsed.provider {
                providers.append(provider)
            } else if let reason = parsed.reason {
                unsupported.append(reason)
            }
        }
        return (providers, unsupported)
    }

    public static func convert(yaml: String, sourceID: UUID) throws -> SubscriptionConversionResult {
        // 解析**之前**先卡输入。`Yams.load` 会把别名逐个展开成独立对象，
        // 实测（2026-09-17 审计探针）：8 路扇出嵌套 6 层、290 字节的文档展开出 210 万个元素、
        // 耗时 0.74 秒，每多一层 ×8——不到 1 KB 的订阅就能把 App 的内存吃光。
        try SubscriptionInputLimits.validate(yaml: yaml)

        guard let root = try Yams.load(yaml: yaml) as? [String: Any],
              let proxies = root["proxies"] as? [[String: Any]] else {
            throw SubscriptionConversionError.missingProxies
        }

        var nodes: [ProxyNode] = []
        var warnings: [String] = []
        // 节点 ID 必须在刷新之间保持稳定：选中节点、各策略组的选择和已测延迟
        // 都以 ID 为键。随机 UUID 会让每次自动刷新都把这些状态清成初始值。
        var nameOccurrences: [String: Int] = [:]
        for raw in proxies {
            do {
                var node = try map(raw, sourceID: sourceID)
                let occurrence = nameOccurrences[node.name, default: 0]
                nameOccurrences[node.name] = occurrence + 1
                node.id = stableNodeID(sourceID: sourceID, name: node.name, occurrence: occurrence)
                nodes.append(node)
            } catch {
                let name = optionalString(raw, "name") ?? "未命名"
                warnings.append("\(name): \(error.localizedDescription)")
            }
        }

        guard !nodes.isEmpty else { throw SubscriptionConversionError.noSupportedNodes }
        guard nodes.count <= SubscriptionInputLimits.nodeLimit else {
            throw SubscriptionConversionError.tooManyEntries(
                kind: "节点", count: nodes.count, limit: SubscriptionInputLimits.nodeLimit
            )
        }
        let groups = policyGroups(from: root)
        var rules = subscriptionRules(from: root)
        guard rules.count <= SubscriptionInputLimits.ruleLimit else {
            throw SubscriptionConversionError.tooManyEntries(
                kind: "分流规则", count: rules.count, limit: SubscriptionInputLimits.ruleLimit
            )
        }
        // 规则集：只保留被 RULE-SET 引用、且形态受支持的；引用了不存在（或不支持）规则集的
        // RULE-SET 一并丢掉——生成配置时引用一个不存在的规则集，内核会整份拒绝。
        let parsedProviders = ruleProviders(from: root)
        let referenced = Set(rules.compactMap { $0.kind == .ruleSet ? $0.value : nil })
        let providers = parsedProviders.providers.filter { referenced.contains($0.name) }
        let providerNames = Set(providers.map(\.name))
        let danglingRuleSets = rules.filter { $0.kind == .ruleSet && !providerNames.contains($0.value) }
        if !danglingRuleSets.isEmpty {
            rules.removeAll { $0.kind == .ruleSet && !providerNames.contains($0.value) }
        }
        let unsupportedReferenced = parsedProviders.unsupported.filter { reason in
            referenced.contains { reason.hasPrefix("\($0)：") }
        }
        if !unsupportedReferenced.isEmpty {
            warnings.append("以下规则集无法使用，引用它们的规则已跳过：" + unsupportedReferenced.joined(separator: "；"))
        }
        let missing = danglingRuleSets.map(\.value).filter { name in
            !parsedProviders.unsupported.contains { $0.hasPrefix("\(name)：") }
        }
        if !missing.isEmpty {
            warnings.append("规则引用了订阅里不存在的规则集，已跳过：" + Set(missing).sorted().joined(separator: "、"))
        }
        let match = matchTarget(from: root)

        let skippedNodes = proxies.count - nodes.count
        let skippedGroups = (root["proxy-groups"] as? [[String: Any]]).map { $0.count - groups.count } ?? 0
        // MATCH 不是"被跳过"：它被取作兜底出口。
        let skippedRules = (root["rules"] as? [String]).map { $0.count - rules.count - (match == nil ? 0 : 1) } ?? 0
        if skippedNodes > 0 || skippedGroups > 0 || skippedRules > 0 {
            warnings.append(
                "订阅兼容性：节点 \(nodes.count) 个已导入/\(skippedNodes) 个跳过，"
                    + "策略组 \(groups.count) 个已导入/\(skippedGroups) 个跳过，"
                    + "规则 \(rules.count) 条已导入/\(skippedRules) 条由内置规则接管或不支持"
            )
        }
        return SubscriptionConversionResult(
            nodes: nodes,
            warnings: warnings,
            policyGroups: groups,
            subscriptionRules: rules,
            ruleProviders: providers,
            matchTarget: match
        )
    }

    /// 由订阅 ID + 节点名（+ 同名序号）推导确定性 UUID：取 SHA-256 前 16 字节，
    /// 按 RFC 4122 拨版本/变体位。同一订阅刷新前后同名节点拿到同一个 ID。
    ///
    /// 注意：严格意义上这不是合法的 UUID v5——RFC 4122 v5 规定用 SHA-1，这里用 SHA-256。
    /// 之所以选 SHA-256：CryptoKit 没有内置 SHA-1，引入会多一个依赖；
    /// 而 UUID 在本项目里只用作稳定 ID，不需要跨系统互操作，所以采用「自定义确定性 UUID」
    /// （合法的 UUID 格式 + 确定性派生），版本位设成 5 只是为了表明"基于名字哈希"的语义。
    static func stableNodeID(sourceID: UUID, name: String, occurrence: Int) -> UUID {
        let material = "\(sourceID.uuidString)|\(name)|\(occurrence)"
        var digest = [UInt8](SHA256.hash(data: Data(material.utf8)))
        digest[6] = (digest[6] & 0x0F) | 0x50   // 版本 5 风格（基于名字哈希）
        digest[8] = (digest[8] & 0x3F) | 0x80   // RFC 4122 变体
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    private static func map(_ raw: [String: Any], sourceID: UUID) throws -> ProxyNode {
        let name = try requiredString(raw, "name")
        let type = try requiredString(raw, "type").lowercased()
        let server = try requiredString(raw, "server")
        let port = try requiredPort(raw)
        let sni = optionalString(raw, "sni") ?? optionalString(raw, "servername")
        let skipCertificateVerification = bool(raw, "skip-cert-verify")
        let transport = try transport(raw)

        switch type {
        case "ss", "shadowsocks":
            let plugin = try shadowsocksPlugin(raw)
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .shadowsocks,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                method: try requiredString(raw, "cipher"),
                transport: transport,
                pluginName: plugin?.name,
                pluginOptions: plugin?.options
            )

        case "trojan":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .trojan,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                tlsEnabled: true,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                transport: transport
            )

        case "vmess":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .vmess,
                server: server,
                port: port,
                uuid: try requiredString(raw, "uuid"),
                security: optionalString(raw, "cipher") ?? optionalString(raw, "security") ?? "auto",
                alterID: int(raw, "alterId") ?? int(raw, "alter-id"),
                tlsEnabled: bool(raw, "tls"),
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                transport: transport
            )

        case "vless":
            let reality = raw["reality-opts"] as? [String: Any]
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .vless,
                server: server,
                port: port,
                uuid: try requiredString(raw, "uuid"),
                tlsEnabled: bool(raw, "tls") || reality != nil,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                transport: transport,
                flow: optionalString(raw, "flow"),
                utlsFingerprint: optionalString(raw, "client-fingerprint")
                    ?? optionalString(raw, "fingerprint"),
                realityPublicKey: optionalString(reality ?? [:], "public-key"),
                realityShortID: optionalString(reality ?? [:], "short-id")
            )

        case "hysteria2", "hy2":
            if let obfs = optionalString(raw, "obfs"), obfs.lowercased() != "salamander" {
                throw NodeMappingError.unsupportedObfs(obfs)
            }
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .hysteria2,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                tlsEnabled: true,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification,
                obfsPassword: optionalString(raw, "obfs-password"),
                uploadMbps: bandwidth(raw, "up"),
                downloadMbps: bandwidth(raw, "down")
            )

        case "anytls":
            return ProxyNode(
                sourceID: sourceID,
                name: name,
                protocolType: .anytls,
                server: server,
                port: port,
                password: try requiredString(raw, "password"),
                tlsEnabled: true,
                sni: sni,
                skipCertificateVerification: skipCertificateVerification
            )

        default:
            throw NodeMappingError.unsupportedProtocol(type)
        }
    }

    private static func transport(_ raw: [String: Any]) throws -> TransportOptions? {
        guard let network = optionalString(raw, "network")?.lowercased() else { return nil }
        switch network {
        case "tcp":
            return nil
        case "ws":
            let options = raw["ws-opts"] as? [String: Any]
            let rawHeaders = options?["headers"] as? [String: Any] ?? [:]
            let headers = rawHeaders.reduce(into: [String: String]()) { result, item in
                result[item.key] = String(describing: item.value)
            }
            return TransportOptions(
                kind: .websocket,
                path: optionalString(options ?? [:], "path"),
                headers: headers
            )
        case "grpc":
            let options = raw["grpc-opts"] as? [String: Any]
            return TransportOptions(
                kind: .grpc,
                serviceName: optionalString(options ?? [:], "grpc-service-name")
                    ?? optionalString(options ?? [:], "service-name")
            )
        default:
            throw NodeMappingError.unsupportedTransport(network)
        }
    }

    /// Clash SS 的 SIP003 插件 → sing-box。目前只支持 simple-obfs（`plugin: obfs`，
    /// 机场最常用），转成 sing-box 的 `obfs-local` + `obfs=<mode>;obfs-host=<host>`。
    /// 其它插件(v2ray-plugin/shadow-tls…)暂不支持，抛错让该节点被跳过并计入 warnings，
    /// 而不是静默生成一个"能握手却传不了数据"的坏节点。
    private static func shadowsocksPlugin(_ raw: [String: Any]) throws -> (name: String, options: String)? {
        guard let plugin = optionalString(raw, "plugin")?.lowercased() else { return nil }
        let opts = raw["plugin-opts"] as? [String: Any] ?? [:]
        switch plugin {
        case "obfs", "obfs-local", "simple-obfs":
            let mode = optionalString(opts, "mode") ?? "http"
            var options = "obfs=\(mode)"
            if let host = optionalString(opts, "host") { options += ";obfs-host=\(host)" }
            return ("obfs-local", options)
        default:
            throw NodeMappingError.unsupportedPlugin(plugin)
        }
    }

    private static func requiredPort(_ raw: [String: Any]) throws -> Int {
        guard let port = int(raw, "port"), (1...65_535).contains(port) else {
            throw NodeMappingError.invalidPort
        }
        return port
    }

    private static func requiredString(_ raw: [String: Any], _ key: String) throws -> String {
        guard let value = optionalString(raw, key) else { throw NodeMappingError.missingField(key) }
        return value
    }

    private static func optionalString(_ raw: [String: Any], _ key: String) -> String? {
        guard let value = raw[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func int(_ raw: [String: Any], _ key: String) -> Int? {
        if let value = raw[key] as? Int { return value }
        if let value = raw[key] as? String { return Int(value) }
        return nil
    }

    private static func bool(_ raw: [String: Any], _ key: String) -> Bool {
        if let value = raw[key] as? Bool { return value }
        if let value = raw[key] as? String { return ["true", "yes", "1"].contains(value.lowercased()) }
        return false
    }

    private static func bandwidth(_ raw: [String: Any], _ key: String) -> Int? {
        if let value = int(raw, key) { return value > 0 ? value : nil }
        guard let text = optionalString(raw, key),
              let digits = text.split(whereSeparator: { !$0.isNumber }).first,
              let value = Int(digits), value > 0 else { return nil }
        return value
    }
}

private enum NodeMappingError: Error, LocalizedError {
    case missingField(String)
    case invalidPort
    case unsupportedProtocol(String)
    case unsupportedTransport(String)
    case unsupportedObfs(String)
    case unsupportedPlugin(String)

    var errorDescription: String? {
        switch self {
        case let .missingField(field): "缺少 \(field)"
        case .invalidPort: "port 必须在 1 到 65535 之间"
        case let .unsupportedProtocol(value): "不支持的协议 \(value)"
        case let .unsupportedTransport(value): "不支持的传输方式 \(value)"
        case let .unsupportedObfs(value): "不支持的 Hysteria2 obfs \(value)"
        case let .unsupportedPlugin(value): "不支持的 SS 插件 \(value)"
        }
    }
}
