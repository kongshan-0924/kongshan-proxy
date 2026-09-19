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
    /// 订阅自带的分流规则，按顺序排在用户规则与绕过之后。含单条规则、RULE-SET 与 GEOIP。
    public let subscriptionRules: [SubscriptionRule]
    /// 已下载就绪的订阅规则集（按 `rule-providers` 名索引）。没就绪的 RULE-SET 会被跳过，
    /// 而不是写进配置——引用一个不存在的规则集，内核会整份拒绝。
    public let subscriptionRuleSets: [String: PreparedSubscriptionRuleSet]
    /// 订阅 `MATCH,<目标>` 的目标：规则模式下作为兜底出口。
    public let matchTarget: String?

    public init(
        settings: RoutingSettings,
        ruleSets: PreparedRuleSets,
        subscriptionRules: [SubscriptionRule] = [],
        subscriptionRuleSets: [String: PreparedSubscriptionRuleSet] = [:],
        matchTarget: String? = nil
    ) {
        self.settings = settings
        self.ruleSets = ruleSets
        self.subscriptionRules = subscriptionRules
        self.subscriptionRuleSets = subscriptionRuleSets
        self.matchTarget = matchTarget
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
    /// TUN 接管系统 DNS **之前**探测到的内网 DNS 与搜索域。空则不生成内网分流。
    public let lanResolver: LANResolverSnapshot
    /// sing-box runtime log level. Normal operation uses info; the app may
    /// temporarily request debug for its bounded diagnostic mode.
    public let coreLogLevel: String

    /// SSH ProxyCommand 同样需要 mixed 入站，但不代表要修改 macOS 系统代理。
    public var usesSystemProxy: Bool {
        enabledModes.contains(.systemProxy) || routing?.settings.sshProxyTargets.isEmpty == false
    }
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
        groupDefaults: [String: String] = [:],
        lanResolver: LANResolverSnapshot = .empty,
        coreLogLevel: String = "info"
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
        self.lanResolver = lanResolver
        self.coreLogLevel = coreLogLevel
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

/// 配置生成结果。warnings 供 AppState 上层透传给用户（非致命问题）。
public struct ConfigGenerationResult: Sendable {
    public let config: Data
    public let warnings: [String]

    public init(config: Data, warnings: [String]) {
        self.config = config
        self.warnings = warnings
    }
}

public enum ConfigGenerator {
    private static let tunFakeIPv4Range = "240.0.0.0/4"

    public static func outboundTag(for node: ProxyNode) -> String {
        "node-\(node.id.uuidString.lowercased())"
    }

    /// 机场"轮辐"结构的主组：被 ≥2 个其它组当作"首个成员(默认)"引用、且自身是代理组
    /// (非纯直连/拒绝包装)的那个，如 TAGSS。它汇聚全部节点、其它策略默认指向它，是用户挑主节点
    /// 的地方。≥2 把汇聚型主组与只被引用一次的地区子组(香港/日本)区分开，避免误判。
    /// AppState 也用它同步"当前节点"，故提取为可共享的纯函数。
    public static func primaryGroupName(among groups: [PolicyGroup]) -> String? {
        func isWrapper(_ g: PolicyGroup) -> Bool {
            let ms = g.members.map { $0.uppercased() }
            guard !ms.isEmpty else { return false }
            return ms.allSatisfy { $0 == "DIRECT" } || ms.allSatisfy { $0 == "REJECT" || $0 == "REJECT-DROP" }
        }
        let proxyGroupNames = Set(groups.filter { !isWrapper($0) }.map(\.name))
        var firstMemberRefs: [String: Int] = [:]
        for g in groups { if let first = g.members.first { firstMemberRefs[first, default: 0] += 1 } }
        return firstMemberRefs
            .filter { proxyGroupNames.contains($0.key) && $0.value >= 2 }
            .max { $0.value < $1.value }?.key
    }

    public static func generate(_ input: ConfigInput) throws -> Data {
        try generateWithWarnings(input).config
    }

    public static func generateWithWarnings(_ input: ConfigInput) throws -> ConfigGenerationResult {
        guard !input.nodes.isEmpty else { throw ConfigGenerationError.noNodes }

        var warnings: [String] = []
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

        // 配置自带策略组（机场的 Netflix / 香港 … 或用户自建组）。
        let groups = (try? input.routing?.settings.validated().policyGroups) ?? []
        // 同名节点冲突记录 warning：机场若给了两个同名节点，策略组按名字引用时只能解析到第一个，
        // 第二个节点的 tag（已是唯一 UUID 形式 node-<uuid>）不会被任何组用到。
        // 不静默吞掉——告诉用户，让他们知道这些节点在机场主组里其实没生效。
        var seenNames: Set<String> = []
        var duplicateNames: Set<String> = []
        for node in input.nodes {
            if !seenNames.insert(node.name).inserted {
                duplicateNames.insert(node.name)
            }
        }
        if !duplicateNames.isEmpty {
            let sorted = duplicateNames.sorted()
            warnings.append(
                "机场下发存在同名节点：\(sorted.joined(separator: "、"))。策略组按名字解析时只会命中第一个，其余同名节点不会出现在组里。"
            )
        }
        let nodeNameToTag = Dictionary(
            input.nodes.map { ($0.name, outboundTag(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let hasAirportGroups = !groups.isEmpty
        let masterGroup = primaryGroupName(among: groups)

        // 内置「手动选择/自动选择」只在机场没有自带策略组时生成，作为纯手动/自建节点的兜底选择器；
        // 有机场组时完全不生成——用户直接在机场主组里挑主节点（对应 Stash：只用配置自带的策略组）。
        var generatedNames = Set(groups.map(\.name))
        if !hasAirportGroups {
            outbounds.append([
                "type": "selector", "tag": "手动选择",
                "outbounds": nodeTags, "default": selectedTag
            ])
            outbounds.append([
                "type": "urltest", "tag": "自动选择",
                "outbounds": nodeTags, "url": input.testURL, "interval": "5m"
            ])
            generatedNames.formUnion(["手动选择", "自动选择"])
        }
        let manualTags = input.nodes.filter { $0.sourceID == nil }.map(outboundTag)
        if !manualTags.isEmpty { generatedNames.insert("自建") }

        // 主/兜底出站：有机场组→主组；识别不到主组(层级式机场)退到用户选的节点；无机场组→手动选择。
        let primaryOutbound = hasAirportGroups ? (masterGroup ?? selectedTag) : "手动选择"

        // 每个 selector 的默认出站（tag）。DNS 要据此判定一条规则的目标最终是直连还是代理——
        // 与这里写进配置的 `default` 用同一份数据，保证路由与 DNS 永远一致。
        var selectorDefaults: [String: String] = [:]
        for group in groups {
            // 成员名解析成出站 tag；解析不到的丢弃，全丢光则回退到全部节点，避免空组让内核校验失败。
            var members = group.members.compactMap { member -> String? in
                switch member.uppercased() {
                case "DIRECT": return "direct"
                case "REJECT", "REJECT-DROP": return "reject"
                default:
                    if let tag = nodeNameToTag[member] { return tag }
                    return generatedNames.contains(member) ? member : nil
                }
            }
            if members.isEmpty { members = nodeTags }
            switch group.kind {
            case .selector:
                let remembered = input.groupDefaults[group.name].flatMap { members.contains($0) ? $0 : nil }
                let def: String
                if group.name == masterGroup {
                    // 主组＝用户挑主节点的地方：默认必须指向真实节点（记住的→App 当前节点→首个节点成员），
                    // 绝不默认走机场的"绕过代理"直连，否则开了代理仍全走直连。
                    def = remembered
                        ?? (members.contains(selectedTag) ? selectedTag : nil)
                        ?? members.first { $0.hasPrefix("node-") }
                        ?? members[0]
                } else {
                    def = remembered ?? members[0]
                }
                selectorDefaults[group.name] = def
                outbounds.append([
                    "type": "selector", "tag": group.name,
                    "outbounds": members, "default": def
                ])
            case .urltest:
                outbounds.append([
                    "type": "urltest", "tag": group.name,
                    "outbounds": members, "url": input.testURL, "interval": "5m"
                ])
            }
        }

        if !manualTags.isEmpty {
            let remembered = input.groupDefaults["自建"].flatMap { manualTags.contains($0) ? $0 : nil }
            outbounds.append([
                "type": "selector", "tag": "自建",
                "outbounds": manualTags, "default": remembered ?? manualTags[0]
            ])
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        outbounds.append(["type": "block", "tag": "reject"])

        let lanResolver = LANResolver.effective(settings: input.tunSettings, detected: input.lanResolver)
        let availableGroups = generatedNames.union(nodeTags)
        var route = try route(
            for: input.routing,
            outboundMode: input.outboundMode,
            primaryOutbound: primaryOutbound,
            availableGroups: availableGroups,
            lanDomainSuffixes: lanResolver.isUsable ? lanResolver.searchDomains : []
        )
        // 订阅规则集的 DNS 规则（只在规则模式、且启用订阅规则时）。DNS 用的纯域名规则集
        // 也要声明在 route.rule_set 里——sing-box 的规则集统一在那里定义，DNS 规则按 tag 引用。
        let subscriptionDNS: SubscriptionDNSRules
        if input.outboundMode == .rule, let routing = input.routing,
           (try? routing.settings.validated())?.useSubscriptionRules == true {
            subscriptionDNS = subscriptionDNSRules(
                routing.subscriptionRules,
                ruleSets: routing.subscriptionRuleSets,
                available: availableGroups.union(["direct", "reject"]),
                selectorDefaults: selectorDefaults,
                useFakeIP: input.usesTun && input.outboundMode != .direct
            )
        } else {
            subscriptionDNS = SubscriptionDNSRules()
        }
        if !subscriptionDNS.definitions.isEmpty {
            var ruleSets = route["rule_set"] as? [[String: Any]] ?? []
            ruleSets.append(contentsOf: subscriptionDNS.definitions)
            route["rule_set"] = ruleSets
        }
        // 引导解析器固定走无连接的 UDP，**不能用 DoH**。见 dns(for:primaryOutbound:) 里的说明。
        route["default_domain_resolver"] = "dns-bootstrap"
        var prefixRules: [[String: Any]] = []
        if input.outboundMode == .rule {
            // SOCKS 客户端可能只送 IP 过来；不嗅探的话域名规则整条落空，
            // 全靠 geoip 兜底。TUN 之外的 mixed 入站同样受益。
            prefixRules.append(["action": "sniff"])
        }
        if input.usesTun {
            route["auto_detect_interface"] = true
            prefixRules.append(["protocol": "dns", "action": "hijack-dns"])
            if input.outboundMode != .direct {
                // 物理网关与部分订阅规则也会占用 198.18/15；改用独立的保留 Class E 段，
                // 并在订阅规则前固定还原到代理路径，避免外部 Fake-IP 与本内核映射混淆。
                prefixRules.append([
                    "ip_cidr": [Self.tunFakeIPv4Range],
                    "action": "route",
                    "outbound": primaryOutbound
                ])
            }
        }
        if !prefixRules.isEmpty {
            var rules = route["rules"] as? [[String: Any]] ?? []
            rules.insert(contentsOf: prefixRules, at: 0)
            route["rules"] = rules
        }

        var experimental: [String: Any] = [
            "clash_api": [
                "external_controller": "127.0.0.1:\(input.runtime.clashPort)",
                "secret": input.runtime.secret
            ]
        ]
        if input.usesTun && input.outboundMode != .direct {
            // macOS 和浏览器可能继续缓存上一次内核分配的 Fake-IP。内核重启后若映射丢失，
            // 旧地址会直接 connection refused；官方 cache_file 持久化映射即可跨重启复用。
            experimental["cache_file"] = [
                "enabled": true,
                "path": AppIdentity.supportDirectory.appending(path: "fakeip-cache-v2.db").path,
                "store_fakeip": true
            ]
        }

        let root: [String: Any] = [
            "log": ["level": input.coreLogLevel, "timestamp": true],
            "dns": try dns(for: input, primaryOutbound: primaryOutbound, subscriptionRules: subscriptionDNS.rules),
            "inbounds": try inbounds(for: input),
            "outbounds": outbounds,
            "route": route,
            "experimental": experimental
        ]
        let config = try encode(root)
        return ConfigGenerationResult(config: config, warnings: warnings)
    }

    /// 解析结果的地址族排序。
    ///
    /// 直连路径经常没有可用的 IPv6 出口，解析器却照样返回 AAAA。内核挑中 AAAA 去 dial，
    /// 结果是 `network is unreachable` / `no route to host`，或者干耗到超时——
    /// 真机 2026-08-26 日志里 `pve.<内网域>` 与 `t2.baidu.com` 都是这么失败的。
    ///
    /// 用 `prefer_ipv4` 而不是 `ipv4_only`：只调**顺序**，没有 A 记录时照样返回 AAAA，
    /// 不会把纯 IPv6 的目标变成不可达。
    ///
    /// 放在 `dns.strategy` 而不是各个 server 的 `domain_strategy` 上，两个理由：
    /// 一是 server 级 `domain_strategy` 管的是「解析这台 DNS 自己的域名」，不是它返回的答案，
    /// 语义根本不对；二是它与 `domain_resolver` 同时出现会命中 sing-box 1.12 的
    /// legacy 弃用检查，1.14 直接移除（真机 `sing-box check` 已报 FATAL）。
    /// 全局生效也覆盖了「由 dns-remote 解析、却被 geoip-cn/ip_is_private 判回直连」这条路径；
    /// 对走代理的域名无害——出站拿到的是域名本身，排序由对端决定。
    private static let domainStrategy = "prefer_ipv4"

    private static func dns(
        for input: ConfigInput,
        primaryOutbound: String,
        subscriptionRules: [[String: Any]] = []
    ) throws -> [String: Any] {
        let endpoints = try input.dnsSettings.endpoints()
        var servers: [[String: Any]] = []

        // 引导解析器：**必须无连接**，所以固定 UDP，不能复用 DoH。
        //
        // DoH 是一条长连接（HTTP/2 over TLS）。路由器 NAT 把它悄悄回收后 sing-box 察觉不到，
        // 后续查询写进死 socket，一直卡到 10 秒超时才失败。而 route.default_domain_resolver
        // 负责解析**出站节点自己的域名**——它一卡，整个代理跟着停摆，不只是某个网站打不开。
        //
        // 真机实证（0.1.46 日志）：每 ~16 分钟一簇失败，节点域名 `<节点>.example` 与
        // 一批国内域名同时报 10.0s `context deadline exceeded`，末尾露出真相
        // `read tcp <本机>->223.5.5.5:443: read: operation timed out`；
        // 同一时刻用 curl 新建连接打同一个 DoH 端点 20/20 成功、30~56ms——服务器没问题，
        // 是那条被复用的连接死了。UDP 每次查询独立收发，天然免疫这种陈旧连接。
        //
        // 安全上可接受：节点域名若被投毒，客户端会连到错误 IP，在 TLS/Reality 校验处
        // 失败关闭，不会把凭据送出去。国内网站的解析仍走 DoH，隐私与抗投毒不受影响。
        //
        // 上游选址：默认跟随国内 DoH 的 IP（用户换掉阿里后，节点域名也不再问阿里）；
        // 用户显式指定 `bootstrapResolver` 时使用独立上游，与国内 DoH 解耦，
        // 一台上游抖动不会同时打掉两类解析。
        let bootstrap = input.dnsSettings.bootstrapResolver
            .trimmingCharacters(in: .whitespacesAndNewlines)
        servers.append([
            "type": "udp",
            "tag": "dns-bootstrap",
            "server": bootstrap.isEmpty
                ? (endpoints.domestic.hostIsIPAddress ? endpoints.domestic.host : "223.5.5.5")
                : bootstrap,
            "server_port": 53
        ])

        var domestic = dohServer(
            endpoint: endpoints.domestic,
            tag: "dns-cn",
            detour: nil
        )
        if !endpoints.domestic.hostIsIPAddress {
            domestic["domain_resolver"] = "dns-bootstrap"
        }
        servers.append(domestic)

        // 内网 DNS：把内网域名交给内网自己的 DNS，而不是让它落到 fakeip。
        // 不加这条，内网域名会拿到 240.0.0.0/4 的假 IP，而假 IP 整段被路由进代理出口，
        // 于是内网设备表现为"一直在加载"——流量被送去国外节点连你办公室的机器。
        // 详见 `LANResolverSnapshot` 的注释（含真机证据）。
        let lan = LANResolver.effective(settings: input.tunSettings, detected: input.lanResolver)
        if lan.isUsable, let lanServer = lan.servers.first {
            servers.append([
                "type": "udp",
                "tag": "dns-lan",
                "server": lanServer,
                "server_port": 53
            ])
        }

        var remote = dohServer(
            endpoint: endpoints.remote,
            tag: "dns-remote",
            detour: primaryOutbound
        )
        if !endpoints.remote.hostIsIPAddress {
            remote["domain_resolver"] = "dns-cn"
        }
        servers.append(remote)

        // fakeip：TUN 下给非国内域名立刻返回假 IP，不等上游解析。
        // "DNS 走 TUN 去上游解析再回来"在部分网络（多默认网关/企业网）会超时或丢失，导致域名
        // 全解析不了、网页全打不开；fakeip 绕开这一步，真实解析交给代理出口那端完成
        // （mihomo/其它客户端在 TUN 下默认即用 fakeip）。仅 IPv4 段，避免与 fc00::/7 排除冲突。
        // 系统代理模式不需要（走 socket、DNS 不经 TUN），保持原 real-ip 行为不变。
        let useFakeIP = input.usesTun && input.outboundMode != .direct
        if useFakeIP {
            servers.append([
                "type": "fakeip",
                "tag": "dns-fakeip",
                "inet4_range": Self.tunFakeIPv4Range
            ])
        }

        var rules: [[String: Any]] = []
        // **必须排在 geosite-cn 与 fakeip 之前**：内网域名常常长得像公网域名
        // （真机遇到的 AD 域就是个 `.com`），既不会命中 geosite-cn，也就必然掉进 fakeip。
        if lan.isUsable {
            rules.append([
                "domain_suffix": lan.searchDomains,
                "action": "route",
                "server": "dns-lan"
            ])
        }
        // 直连域名的解析也必须留在国内解析器。它们在**路由**上走 direct，可**解析**上
        // 既不命中内网规则、也多半不在 geosite-cn 里，于是掉到 `final: dns-remote`——
        // 经代理去问 8.8.8.8，再把答案拿回本地直连。绕远一圈的代价是双份的：
        // 解析本身随代理一起抖（真机 2026-08-26：旁路的内网域每次卡满 10 秒，两小时 26 次失败），
        // 拿回来的还可能是本地根本连不通的地址。
        // 与上面的内网规则同理，**必须排在 geosite-cn 与 fakeip 之前**。
        if input.outboundMode == .rule, let settings = try input.routing?.settings.validated() {
            // 自定义规则里指向代理的域名先截胡。路由上自定义规则优先于旁路，DNS 上也必须
            // 保持同一优先级：否则 fakeip 模式下这些域名会拿到真实 IP 而不是假 IP，
            // 失去域名信息后按 IP 匹配路由，就走错出口了。
            for rule in settings.customRules where rule.enabled && rule.action == .proxy {
                guard let field = dnsRuleField(for: rule.type) else { continue }
                rules.append([field: [rule.value], "action": "route", "server": "dns-remote"])
            }
            let bypass = splitBypassDomains(settings.bypassDomains)
            var bypassDNS: [String: Any] = ["action": "route", "server": "dns-cn"]
            if !bypass.exact.isEmpty { bypassDNS["domain"] = bypass.exact }
            if !bypass.suffixes.isEmpty { bypassDNS["domain_suffix"] = bypass.suffixes }
            if bypassDNS.count > 2 { rules.append(bypassDNS) }
        }
        // 订阅规则集：排在用户自定义与强制直连之后（与路由同一优先级），在 geosite-cn 与 fakeip 之前。
        // 直连名单（直连 / 国内 / 内网 / 解锁 …）走国内解析器拿真实、本地可达的地址；
        // 不加的话 TUN（fake-ip）下这些域名拿到假 IP，内网与直连域名解析就不对。
        rules.append(contentsOf: subscriptionRules)
        // 反向解析与 Bonjour 发现（`*.in-addr.arpa` / `*.ip6.arpa` / `lb._dns-sd._udp.*`）留在本地解析器。
        // TUN 劫持 DNS 后 macOS 会不停发这类 PTR 查询，不加这条它们掉到 `final: dns-remote`——
        // 经代理去问 8.8.8.8：既白跑（公网解析器不认内网反向域），又把内网网段信息送出去。
        // 真机 2026-09-03 一天 73 条此类失败（换网/重载期间 closed pipe、context canceled）。
        let localResolver = lan.isUsable ? "dns-lan" : "dns-cn"
        rules.append([
            "domain_suffix": ["in-addr.arpa", "ip6.arpa"],
            "action": "route",
            "server": localResolver
        ])
        rules.append([
            "domain_keyword": ["_dns-sd._udp"],
            "action": "route",
            "server": localResolver
        ])
        if input.routing != nil, input.outboundMode == .rule {
            rules.append([
                "rule_set": "geosite-cn",
                "action": "route",
                "server": "dns-cn"
            ])
        }
        if useFakeIP {
            // 国内域名上面已走 dns-cn 拿真实 IP 直连；其余 A/AAAA 查询走 fakeip。
            rules.append([
                "query_type": ["A", "AAAA"],
                "action": "route",
                "server": "dns-fakeip"
            ])
        }

        var result: [String: Any] = [
            "servers": servers,
            "rules": rules,
            "strategy": Self.domainStrategy,
            // 直连模式不应把解析绕到代理出口
            "final": input.outboundMode == .direct ? "dns-cn" : "dns-remote"
        ]
        if useFakeIP {
            // fakeip 需要独立缓存，避免与普通 DNS 缓存互相污染。
            result["independent_cache"] = true
        }
        return result
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
                // 强制 gvisor 用户态栈：system/mixed 栈的 TCP 转发在部分网络（多默认网关/企业网等）
                // 会失效——只有 UDP/ICMP 通、网页(TCP)全打不开。gvisor 用户态栈普遍兼容
                // （mihomo/其它客户端默认即此），实测能修好这类"TUN 开了网页全挂"。
                "stack": "gvisor"
            ]
            if let routing = input.routing {
                let settings = try routing.settings.validated()
                inbound["route_exclude_address"] = input.outboundMode == .rule
                    ? settings.effectiveTunExcludeCIDRs
                    : settings.tunExcludeCIDRs
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

    /// 把订阅规则按「连续的同字段、同出站」合并成一条（多个值放进同一数组）。
    /// 机场动辄几千条独立规则会让配置膨胀到 1MB+，拖慢生成/编码/内核解析，界面也会卡。
    /// 合并后通常只剩一两百条；语义不变——单条规则里同一字段的多值是「或」，等价于多条连续规则；
    /// 只合并「连续」段，因此匹配顺序（首个命中生效）与合并前完全一致。
    ///
    /// `RULE-SET` 生成 `rule_set: <tag>` 引用；连续、同出站的几个规则集同样合并成一条
    /// （`rule_set` 数组内也是「或」）。**没就绪的规则集直接跳过**——引用不存在的规则集，
    /// 内核会整份拒绝配置；跳过只是退回到没有这条规则的状态。
    /// `GEOIP,CN` 原位引用内置 `geoip-cn`；其他国家码没有本地库，跳过。
    static func mergedSubscriptionRules(
        _ subscriptionRules: [SubscriptionRule],
        available: Set<String>,
        ruleSets: [String: PreparedSubscriptionRuleSet] = [:]
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
            guard let target = resolvedOutbound(for: rule.target, available: available),
                  let (ruleField, value) = routeMatcher(for: rule, ruleSets: ruleSets) else { continue }
            if ruleField == field, target == outbound {
                values.append(value)
            } else {
                flush()
                field = ruleField
                outbound = target
                values = [value]
            }
        }
        flush()
        return result
    }

    /// 一条订阅规则在路由里的匹配字段与值；无法生成（规则集没就绪、GEOIP 非 CN）时为 nil。
    private static func routeMatcher(
        for rule: SubscriptionRule,
        ruleSets: [String: PreparedSubscriptionRuleSet]
    ) -> (String, String)? {
        switch rule.kind {
        case let .single(type):
            return (ruleField(for: type), rule.value)
        case .ruleSet:
            guard let prepared = ruleSets[rule.value] else { return nil }
            return ("rule_set", prepared.routeTag)
        case .geoIP:
            return rule.value == "CN" ? ("rule_set", "geoip-cn") : nil
        }
    }

    /// 一条规则的目标最终落到哪类出口。沿着 selector 的默认出站一路解析到底：
    /// 「苹果服务 → 全球直连 → DIRECT」这种两跳在真实订阅里就有。
    enum TargetKind: Equatable {
        case direct
        case reject
        case proxy
    }

    static func targetKind(of tag: String, selectorDefaults: [String: String], depth: Int = 0) -> TargetKind {
        switch tag.lowercased() {
        case "direct": return .direct
        case "reject", "reject-drop": return .reject
        default:
            // 组套组有环、或深度异常：按代理处理（最保守——不会把代理流量的解析错送到国内）。
            guard depth < 8, let next = selectorDefaults[tag] else { return .proxy }
            return targetKind(of: next, selectorDefaults: selectorDefaults, depth: depth + 1)
        }
    }

    struct SubscriptionDNSRules {
        var rules: [[String: Any]] = []
        /// 需要声明在 route.rule_set 里的纯域名规则集。
        var definitions: [[String: Any]] = []
    }

    /// 订阅规则集对应的 DNS 规则，**按订阅顺序**生成，与路由优先级一致。
    ///
    /// 直连目标 → `dns-cn`（真实、本地可达的地址）；代理目标 → fake-ip 下走 `dns-fakeip`、
    /// 否则走 `dns-remote`；拦截目标不生成（路由会直接拒掉连接）。
    ///
    /// **代理目标也必须生成**：一个域名若同时出现在前面的代理规则集和后面的 `cn` 直连集里，
    /// 路由上前者先命中、走代理；DNS 上若只给直连集加规则，它就会被后面的直连规则截走、
    /// 拿到国内解析结果——路由与解析两边就不一致了。按顺序逐条生成才能镜像路由的优先级。
    ///
    /// 只用规则集的**纯域名版本**：DNS 规则只能按域名匹配（见 `RuleSetContent.singBoxDNSSource`）。
    static func subscriptionDNSRules(
        _ subscriptionRules: [SubscriptionRule],
        ruleSets: [String: PreparedSubscriptionRuleSet],
        available: Set<String>,
        selectorDefaults: [String: String],
        useFakeIP: Bool
    ) -> SubscriptionDNSRules {
        var result = SubscriptionDNSRules()
        var declared = Set<String>()
        var server: String?
        var tags: [String] = []

        func flush() {
            if let server, !tags.isEmpty {
                var rule: [String: Any] = ["rule_set": tags, "action": "route", "server": server]
                // 与默认的 fakeip 规则一致：fakeip 只应答 A / AAAA。
                if server == "dns-fakeip" { rule["query_type"] = ["A", "AAAA"] }
                result.rules.append(rule)
            }
            tags = []
        }

        for rule in subscriptionRules where rule.kind == .ruleSet {
            guard let prepared = ruleSets[rule.value],
                  let dnsTag = prepared.dnsTag, let dnsFile = prepared.dnsFile,
                  let outbound = resolvedOutbound(for: rule.target, available: available) else { continue }
            let next: String
            switch targetKind(of: outbound, selectorDefaults: selectorDefaults) {
            case .direct: next = "dns-cn"
            case .proxy: next = useFakeIP ? "dns-fakeip" : "dns-remote"
            case .reject: continue
            }
            if next != server {
                flush()
                server = next
            }
            tags.append(dnsTag)
            if declared.insert(dnsTag).inserted {
                result.definitions.append(localRuleSet(tag: dnsTag, path: dnsFile))
            }
        }
        flush()
        return result
    }

    private static func route(
        for routing: RoutingConfiguration?,
        outboundMode: OutboundMode = .rule,
        primaryOutbound: String = "手动选择",
        availableGroups: Set<String> = [],
        lanDomainSuffixes: [String] = []
    ) throws -> [String: Any] {
        let settings = try routing?.settings.validated()
        let sshRules = settings.map { settings in
            settings.sshProxyTargets.map { target in
                [
                    "ip_cidr": [target.hostCIDR],
                    "port": [Int(target.port)],
                    "network": ["tcp"],
                    "action": "route",
                    "outbound": primaryOutbound
                ] as [String: Any]
            }
        } ?? []

        // SSH 显式规则始终优先；全局/直连只决定其他流量的兜底出口。
        switch outboundMode {
        case .global:
            return ["rules": sshRules, "final": primaryOutbound]
        case .direct:
            return ["rules": sshRules, "final": "direct"]
        case .rule:
            break
        }

        guard let routing, let settings else {
            return ["rules": [], "final": primaryOutbound]
        }

        var rules = sshRules
        rules.append(contentsOf: settings.customRules
            .filter(\.enabled)
            .map { customRouteRule($0, fallback: primaryOutbound, available: availableGroups) })

        if let bypass = bypassRule(for: settings, extraDomainSuffixes: lanDomainSuffixes) {
            rules.append(bypass)
        }

        // 订阅自带规则：优先级低于用户规则与绕过，高于内置的私有网段/中国直连。
        // 目标必须能解析到已存在的出站（只认真正生成的出站），否则内核校验会失败，因此逐条过滤。
        var finalOutbound = primaryOutbound
        var subscriptionRuleSetDefinitions: [[String: Any]] = []
        if settings.useSubscriptionRules {
            let available = availableGroups.union(["direct", "reject"])
            rules.append(contentsOf: mergedSubscriptionRules(
                routing.subscriptionRules, available: available, ruleSets: routing.subscriptionRuleSets
            ))
            // 只声明真正被引用、且已就绪的规则集。按订阅顺序，重复引用只声明一次。
            var declared = Set<String>()
            for rule in routing.subscriptionRules where rule.kind == .ruleSet {
                guard let prepared = routing.subscriptionRuleSets[rule.value],
                      resolvedOutbound(for: rule.target, available: available) != nil,
                      declared.insert(prepared.routeTag).inserted else { continue }
                subscriptionRuleSetDefinitions.append(localRuleSet(tag: prepared.routeTag, path: prepared.routeFile))
            }
            // MATCH：订阅指定的兜底出口（如「🐟 漏网之鱼」）。此前被忽略，那个组在界面上能切、
            // 却一点作用都没有。解析不到（组不存在）时退回主出口。
            if let match = routing.matchTarget,
               let outbound = resolvedOutbound(for: match, available: available) {
                finalOutbound = outbound
            }
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
        ruleSets.append(contentsOf: subscriptionRuleSetDefinitions)
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
            "final": finalOutbound
        ]
    }

    /// 自定义规则类型 → **DNS 规则**字段。DNS 规则只能按域名匹配，
    /// `ip_cidr` 在解析阶段还没有 IP，`process_name` 与本函数的用途（域名截胡）无关，
    /// 两者都返回 nil 由调用方跳过，而不是硬塞进去让内核校验失败。
    static func dnsRuleField(for type: CustomRuleType) -> String? {
        switch type {
        case .domainSuffix: "domain_suffix"
        case .domainKeyword: "domain_keyword"
        case .domain: "domain"
        case .ipCIDR, .processName: nil
        }
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

    private static func customRouteRule(
        _ rule: CustomRouteRule,
        fallback: String,
        available: Set<String>
    ) -> [String: Any] {
        let field = ruleField(for: rule.type)

        let outbound: String
        switch rule.action {
        case .direct: outbound = "direct"
        case .proxy:
            if let target = rule.proxyGroup, available.contains(target) {
                outbound = target
            } else {
                outbound = fallback
            }
        case .reject: outbound = "reject"
        }
        return [field: [rule.value], "action": "route", "outbound": outbound]
    }

    /// - Parameter extraDomainSuffixes: 内网域名后缀。除了 DNS 要交给内网 DNS 解析，
    ///   路由上也必须直连——内网域名可能解析到 DMZ 的公网 IP，那时按 IP 判定的
    ///   私有网段规则就落空了，流量还是会被送进代理。
    /// 旁路域名拆成 sing-box 的 `domain` / `domain_suffix` 两类。
    /// **路由与 DNS 两处必须用同一份拆法**——分开各写一遍必然会漂，
    /// 而这两处一旦不一致，就会出现「路由走直连、解析走代理」的错配（见 `dns(for:)`）。
    static func splitBypassDomains(_ domains: [String]) -> (exact: [String], suffixes: [String]) {
        var exact: [String] = []
        var suffixes: [String] = []
        for domain in domains {
            if domain.hasPrefix("*.") {
                suffixes.append(String(domain.dropFirst(2)))
            } else if domain.hasPrefix(".") {
                suffixes.append(String(domain.dropFirst()))
            } else {
                exact.append(domain)
            }
        }
        return (exact, suffixes)
    }

    private static func bypassRule(
        for settings: RoutingSettings,
        extraDomainSuffixes: [String] = []
    ) -> [String: Any]? {
        var (exactDomains, domainSuffixes) = splitBypassDomains(settings.bypassDomains)

        for suffix in extraDomainSuffixes where !domainSuffixes.contains(suffix) {
            domainSuffixes.append(suffix)
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
            if var cacheFile = experimental["cache_file"] as? [String: Any] {
                // 诊断快照可对外分享，不泄露本机用户名所在的绝对路径。
                cacheFile.removeValue(forKey: "path")
                experimental["cache_file"] = cacheFile
            }
            if experimental.isEmpty {
                root.removeValue(forKey: "experimental")
            } else {
                root["experimental"] = experimental
            }
        }
        // 节点凭据同样敏感：用户把 config.json 贴群/发 issue 时若不脱敏，
        // password / uuid / obfs-password 会直接泄漏全部节点凭据。
        // secret 已随 clash_api 一并移除；这里递归遍历所有 outbound 字段。
        if var outbounds = root["outbounds"] as? [[String: Any]] {
            for index in outbounds.indices {
                outbounds[index] = Self.redactOutbound(outbounds[index])
            }
            root["outbounds"] = outbounds
        }
        return try encode(root)
    }

    /// 需要脱敏的字段名（与嵌套层级无关）。加协议时若引入新凭据字段，往这里加一条即可。
    static let redactedFieldNames: Set<String> = [
        "password", "uuid", "secret", "auth", "auth_str", "token", "psk",
        // Reality/uTLS：public_key 虽名为"公钥"，但它和 short_id 唯一标识机场的服务端配置，
        // 诊断包是对外分享的，一并脱敏。
        "private_key", "public_key", "short_id"
    ]

    /// 真·递归脱敏：outbound 的凭据可能嵌在任意层级（`obfs.password`、
    /// `tls.reality.public_key`、`transport.headers.*`…）。只按字段名匹配、
    /// 保留整体结构，新增协议不会因为忘了加分支而漏脱敏。
    private static func redactOutbound(_ outbound: [String: Any]) -> [String: Any] {
        redactValue(outbound) as? [String: Any] ?? outbound
    }

    private static func redactValue(_ value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                if redactedFieldNames.contains(key), nested is String {
                    dictionary[key] = "<redacted>"
                } else {
                    dictionary[key] = redactValue(nested)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map(redactValue)
        }
        return value
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
            // SIP003 插件（simple-obfs 等）。机场绝大多数 SS 节点靠它混淆，
            // 不带的话能握手却传不了数据 → 表现为"节点能测速但打不开网站"。
            if let pluginName = node.pluginName {
                value["plugin"] = pluginName
                if let options = node.pluginOptions { value["plugin_opts"] = options }
            }
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
        case .vless:
            value["uuid"] = try required(node.uuid, node: node, field: "uuid")
            if let flow = node.flow { value["flow"] = flow }
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
        var value: [String: Any] = [
            "enabled": true,
            "server_name": node.sni ?? node.server,
            "insecure": node.skipCertificateVerification
        ]
        if let fingerprint = node.utlsFingerprint {
            value["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        if let publicKey = node.realityPublicKey {
            var reality: [String: Any] = ["enabled": true, "public_key": publicKey]
            if let shortID = node.realityShortID { reality["short_id"] = shortID }
            value["reality"] = reality
        }
        return value
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
