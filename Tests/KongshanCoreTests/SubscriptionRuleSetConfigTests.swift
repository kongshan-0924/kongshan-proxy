import Foundation
import HelperProtocol
import XCTest
@testable import KongshanCore

/// 订阅规则集写进内核配置：路由（第 6 点）、DNS（第 7 点）、MATCH 兜底（第 8 点）。
///
/// 夹具仿照真实订阅的组结构——包括「苹果服务 → 全球直连 → DIRECT」这种两跳：
/// 真实订阅里微软、苹果两组都默认指向全球直连，DNS 必须沿默认出站解析到底才能判成直连。
final class SubscriptionRuleSetConfigTests: XCTestCase {
    private var directory: URL!
    private var builtin: PreparedRuleSets!
    private var prepared: [String: PreparedSubscriptionRuleSet] = [:]

    private let node = ProxyNode(
        name: "N1", protocolType: .shadowsocks, server: "n1.example.com", port: 443,
        password: "p", method: "aes-128-gcm"
    )

    private var groups: [PolicyGroup] {
        func group(_ name: String, _ members: [String]) -> PolicyGroup {
            var g = PolicyGroup(name: name, kind: .selector)
            g.members = members
            return g
        }
        return [
            group("节点选择", ["N1", "DIRECT"]),
            group("全球直连", ["DIRECT", "节点选择"]),
            group("广告拦截", ["REJECT", "DIRECT"]),
            group("苹果服务", ["全球直连", "节点选择"]),
            group("AI", ["节点选择", "N1"]),
            group("漏网之鱼", ["节点选择", "DIRECT"]),
        ]
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "sub-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        builtin = PreparedRuleSets(
            geositeCN: try await compile(#"{"version":1,"rules":[{"domain_suffix":["cn"]}]}"#, "geosite-cn"),
            geoipCN: try await compile(#"{"version":1,"rules":[{"ip_cidr":["1.0.1.0/24"]}]}"#, "geoip-cn"),
            ads: try await compile(#"{"version":1,"rules":[{"domain_suffix":["ads.example"]}]}"#, "ads")
        )
        for (name, withDNS) in [("local-direct", true), ("reject", true), ("ai", true), ("apple", true),
                                ("proxy", true), ("cn", true), ("ips", false)] {
            let route = try await compile(#"{"version":1,"rules":[{"domain_suffix":["\#(name).example"]}]}"#, "\(name)")
            let dns = withDNS ? try await compile(#"{"version":1,"rules":[{"domain_suffix":["\#(name).example"]}]}"#, "\(name).dns") : nil
            prepared[name] = PreparedSubscriptionRuleSet(
                name: name, routeTag: "sub-\(name)", routeFile: route,
                dnsTag: withDNS ? "sub-\(name)-dns" : nil, dnsFile: dns,
                sourceFile: route, entryCount: 1, fetchedAt: Date(), expiresAt: .distantFuture
            )
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func compile(_ json: String, _ name: String) async throws -> URL {
        let source = directory.appending(path: "\(name).json")
        let output = directory.appending(path: "\(name).srs")
        try Data(json.utf8).write(to: source)
        let result = try await ProcessRunner.run(executable: singBoxURL,
                                                 arguments: ["rule-set", "compile", source.path, "-o", output.path],
                                                 timeout: 10)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return output
    }

    private var singBoxURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Vendor/sing-box/sing-box")
    }

    /// 真实订阅的规则顺序（节选）。
    private let rules: [SubscriptionRule] = [
        SubscriptionRule(kind: .ruleSet, value: "local-direct", target: "全球直连"),
        SubscriptionRule(kind: .ruleSet, value: "reject", target: "广告拦截"),
        SubscriptionRule(kind: .ruleSet, value: "ai", target: "AI"),
        SubscriptionRule(kind: .ruleSet, value: "apple", target: "苹果服务"),
        SubscriptionRule(kind: .ruleSet, value: "proxy", target: "节点选择"),
        SubscriptionRule(kind: .ruleSet, value: "cn", target: "全球直连"),
        SubscriptionRule(kind: .geoIP, value: "CN", target: "全球直连"),
    ]

    private func config(
        rules: [SubscriptionRule]? = nil, ruleSets: [String: PreparedSubscriptionRuleSet]? = nil,
        match: String? = "漏网之鱼", modes: Set<ProxyMode> = [.tun, .systemProxy],
        outboundMode: OutboundMode = .rule, useSubscriptionRules: Bool = true,
        groupDefaults: [String: String] = [:]
    ) throws -> [String: Any] {
        var settings = RoutingSettings.defaults
        settings.policyGroups = groups
        settings.blockAds = false
        settings.useSubscriptionRules = useSubscriptionRules
        let input = ConfigInput(
            nodes: [node], selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: String(repeating: "s", count: 32)),
            routing: RoutingConfiguration(settings: settings, ruleSets: builtin, subscriptionRules: rules ?? self.rules,
                                          subscriptionRuleSets: ruleSets ?? prepared, matchTarget: match),
            enabledModes: modes, outboundMode: outboundMode, groupDefaults: groupDefaults
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: ConfigGenerator.generate(input)) as? [String: Any])
    }

    private func routeRules(_ root: [String: Any]) -> [[String: Any]] {
        ((root["route"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
    }

    private func dnsRules(_ root: [String: Any]) -> [[String: Any]] {
        ((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]]) ?? []
    }

    private func ruleSetTags(_ rule: [String: Any]) -> [String] {
        if let tags = rule["rule_set"] as? [String] { return tags }
        if let tag = rule["rule_set"] as? String { return [tag] }
        return []
    }

    // MARK: - 第 6 点：路由

    func testRuleSetReferencesKeepSubscriptionOrder() throws {
        let subscription = routeRules(try config()).filter { ruleSetTags($0).contains { $0.hasPrefix("sub-") } }
        XCTAssertEqual(subscription.map(ruleSetTags), [
            ["sub-local-direct"], ["sub-reject"], ["sub-ai"], ["sub-apple"], ["sub-proxy"],
            ["sub-cn", "geoip-cn"],
        ], "顺序即语义；cn 与相邻同目标的 GEOIP,CN 合并成一条")
        XCTAssertEqual(subscription.map { $0["outbound"] as? String },
                       ["全球直连", "广告拦截", "AI", "苹果服务", "节点选择", "全球直连"])
    }

    /// 没就绪的规则集直接跳过——引用不存在的规则集，内核会整份拒绝配置。
    func testUnpreparedRuleSetIsSkippedNotReferenced() throws {
        var partial = prepared
        partial["ai"] = nil
        let root = try config(ruleSets: partial)
        let all = routeRules(root).flatMap(ruleSetTags)
        XCTAssertFalse(all.contains("sub-ai"))
        let declared = ((root["route"] as? [String: Any])?["rule_set"] as? [[String: Any]])?.compactMap { $0["tag"] as? String } ?? []
        XCTAssertFalse(declared.contains("sub-ai"))
    }

    func testOnlyReferencedRuleSetsAreDeclaredOnce() throws {
        var twice = rules
        twice.append(SubscriptionRule(kind: .ruleSet, value: "ai", target: "节点选择"))
        let declared = ((try config(rules: twice))["route"] as? [String: Any])?["rule_set"] as? [[String: Any]] ?? []
        let tags = declared.compactMap { $0["tag"] as? String }
        XCTAssertEqual(tags.filter { $0 == "sub-ai" }.count, 1, "重复引用只声明一次")
        XCTAssertFalse(tags.contains("sub-ips"), "没被引用的不声明")
    }

    func testNonCNGeoIPIsSkipped() throws {
        let root = try config(rules: [SubscriptionRule(kind: .geoIP, value: "US", target: "节点选择")])
        XCTAssertFalse(routeRules(root).contains { ($0["outbound"] as? String) == "节点选择" && !ruleSetTags($0).isEmpty })
    }

    // MARK: - 第 8 点：MATCH

    func testMatchTargetBecomesFinal() throws {
        XCTAssertEqual((try config())["route"].flatMap { ($0 as? [String: Any])?["final"] as? String }, "漏网之鱼")
    }

    func testUnresolvableMatchFallsBackToPrimary() throws {
        let final = ((try config(match: "不存在的组"))["route"] as? [String: Any])?["final"] as? String
        XCTAssertEqual(final, "节点选择")
    }

    /// 关掉「应用订阅规则」时 MATCH 也不生效——它是订阅规则的一部分。
    func testMatchIgnoredWhenSubscriptionRulesDisabled() throws {
        let root = try config(useSubscriptionRules: false)
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "节点选择")
        XCTAssertFalse(routeRules(root).flatMap(ruleSetTags).contains { $0.hasPrefix("sub-") })
    }

    func testGlobalAndDirectModesIgnoreMatch() throws {
        XCTAssertEqual(((try config(outboundMode: .global))["route"] as? [String: Any])?["final"] as? String, "节点选择")
        XCTAssertEqual(((try config(outboundMode: .direct))["route"] as? [String: Any])?["final"] as? String, "direct")
    }

    // MARK: - 第 7 点：DNS

    /// DNS 规则按订阅顺序镜像路由优先级：直连 → dns-cn、代理 → fakeip、拦截不生成。
    func testDNSMirrorsRoutingOrderAndTargets() throws {
        let subscription = dnsRules(try config()).filter { ruleSetTags($0).contains { $0.hasPrefix("sub-") } }
        XCTAssertEqual(subscription.map(ruleSetTags), [
            ["sub-local-direct-dns"], ["sub-ai-dns"], ["sub-apple-dns"], ["sub-proxy-dns"], ["sub-cn-dns"],
        ])
        XCTAssertEqual(subscription.map { $0["server"] as? String },
                       ["dns-cn", "dns-fakeip", "dns-cn", "dns-fakeip", "dns-cn"])
    }

    /// 两跳：苹果服务 → 全球直连 → DIRECT。只看一跳会把它当成代理，苹果域名就拿到假 IP。
    func testTwoHopDirectTargetResolvesToDomesticDNS() throws {
        let apple = dnsRules(try config()).first { ruleSetTags($0) == ["sub-apple-dns"] }
        XCTAssertEqual(apple?["server"] as? String, "dns-cn")
    }

    /// 用户把「全球直连」切到了节点选择：DNS 必须跟着路由走，否则路由走代理、解析却在国内。
    func testUserSwitchedGroupChangesDNSTarget() throws {
        let root = try config(groupDefaults: ["全球直连": "节点选择"])
        // 切走后 local-direct 与后面同走 fakeip 的 ai 相邻（中间的拦截集在 DNS 里本就不生成），
        // 会合并成一条——按「包含」找，不按整条相等找。
        let direct = dnsRules(root).first { ruleSetTags($0).contains("sub-local-direct-dns") }
        XCTAssertEqual(direct?["server"] as? String, "dns-fakeip")
    }

    /// 代理目标在 fakeip 下只接 A / AAAA（与默认 fakeip 规则一致）；不开 TUN 时走远端解析。
    func testProxyTargetDNSServerDependsOnFakeIP() throws {
        let tun = dnsRules(try config()).first { ruleSetTags($0) == ["sub-ai-dns"] }
        XCTAssertEqual(tun?["query_type"] as? [String], ["A", "AAAA"])
        let proxyOnly = dnsRules(try config(modes: [.systemProxy])).first { ruleSetTags($0) == ["sub-ai-dns"] }
        XCTAssertEqual(proxyOnly?["server"] as? String, "dns-remote")
        XCTAssertNil(proxyOnly?["query_type"])
    }

    /// 必须排在 geosite-cn 与 fakeip 兜底之前，否则永远轮不到它们。
    func testSubscriptionDNSRulesPrecedeGeositeAndFakeIP() throws {
        let rules = dnsRules(try config())
        let lastSub = try XCTUnwrap(rules.lastIndex { ruleSetTags($0).contains { $0.hasPrefix("sub-") } })
        let geosite = try XCTUnwrap(rules.firstIndex { ruleSetTags($0) == ["geosite-cn"] })
        let fakeip = try XCTUnwrap(rules.firstIndex { ($0["server"] as? String) == "dns-fakeip" && ruleSetTags($0).isEmpty })
        XCTAssertLessThan(lastSub, geosite)
        XCTAssertLessThan(lastSub, fakeip)
    }

    /// DNS 规则只能引用纯域名版本；DNS 用的规则集也要声明在 route.rule_set 里。
    func testDNSUsesDomainOnlyVariantsAndDeclaresThem() throws {
        let root = try config()
        let dnsTags = Set(dnsRules(root).flatMap(ruleSetTags).filter { $0.hasPrefix("sub-") })
        XCTAssertTrue(dnsTags.allSatisfy { $0.hasSuffix("-dns") })
        let declared = Set(((root["route"] as? [String: Any])?["rule_set"] as? [[String: Any]])?
            .compactMap { $0["tag"] as? String } ?? [])
        XCTAssertTrue(dnsTags.isSubset(of: declared), "DNS 引用的规则集必须已声明")
    }

    func testRuleSetWithoutDomainContentGetsNoDNSRule() throws {
        let root = try config(rules: [SubscriptionRule(kind: .ruleSet, value: "ips", target: "全球直连")])
        XCTAssertFalse(dnsRules(root).flatMap(ruleSetTags).contains { $0.hasPrefix("sub-ips") })
    }

    /// 只在规则模式下生成：全局 / 直连模式不按订阅规则分流，DNS 也不该按它分。
    func testNoSubscriptionDNSRulesOutsideRuleMode() throws {
        for mode in [OutboundMode.global, .direct] {
            XCTAssertFalse(dnsRules(try config(outboundMode: mode)).flatMap(ruleSetTags).contains { $0.hasPrefix("sub-") })
        }
    }

    func testTargetKindHandlesCyclesConservatively() {
        let cyclic = ["A": "B", "B": "A"]
        XCTAssertEqual(ConfigGenerator.targetKind(of: "A", selectorDefaults: cyclic), .proxy,
                       "有环按代理处理：不会把代理流量的解析错送到国内")
        XCTAssertEqual(ConfigGenerator.targetKind(of: "X", selectorDefaults: ["X": "direct"]), .direct)
        XCTAssertEqual(ConfigGenerator.targetKind(of: "X", selectorDefaults: ["X": "reject"]), .reject)
    }

    // MARK: - 第 3 点：特权助手白名单

    /// TUN 下内核以 root 启动前的最后一道闸：订阅规则集（含 DNS 用的纯域名版本）都声明在
    /// route.rule_set 里、且都在被钉死用户的 App 支持目录内，白名单必须放行；换个目录必须拒。
    func testGeneratedConfigPassesHelperWhitelistOnlyInsideSupportDirectory() throws {
        var settings = RoutingSettings.defaults
        settings.policyGroups = groups
        let input = ConfigInput(
            nodes: [node], selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: String(repeating: "s", count: 32)),
            routing: RoutingConfiguration(settings: settings, ruleSets: builtin, subscriptionRules: rules,
                                          subscriptionRuleSets: prepared, matchTarget: "漏网之鱼"),
            enabledModes: [.tun], outboundMode: .rule
        )
        let data = try ConfigGenerator.generate(input)
        let inside = HelperConfigWhitelist.validate(data, allowedRuleSetDirectory: directory.path)
        XCTAssertTrue(inside.ok, inside.reason ?? "")
        XCTAssertTrue(inside.ruleSetPaths.contains { $0.hasSuffix("ai.dns.srs") }, "DNS 用的规则集也要交给助手做 realpath 复核")
        let elsewhere = HelperConfigWhitelist.validate(data, allowedRuleSetDirectory: "/Users/someone-else/Library")
        XCTAssertFalse(elsewhere.ok)
    }

    // MARK: - 占位：配置与下载进度无关

    /// 首次启动还没下载时，全用空占位也能生成配置、过白名单与内核校验；下载完成后再生成，
    /// 配置**完全不变**——这正是下载完不用重启内核的前提（内核自己重载被原子替换的文件）。
    func testPlaceholderConfigPassesChecksAndStaysIdenticalAfterDownload() async throws {
        let providers = rules.filter { $0.kind == .ruleSet }.map { rule in
            SubscriptionRuleProvider(
                name: rule.value, url: URL(string: "https://rules.example.com/\(rule.value).yaml")!,
                behavior: .classical, format: .yaml, interval: nil
            )
        }
        let service = SubscriptionRuleSetService(
            storage: Storage(rootDirectory: directory),
            downloader: { url, _ in
                Data("payload:\n  - DOMAIN-SUFFIX,\(url.deletingPathExtension().lastPathComponent).example\n".utf8)
            },
            compiler: SubscriptionRuleSetService.coreCompiler(binaryURL: singBoxURL)
        )
        let sourceID = UUID()
        func generate(_ ruleSets: [String: PreparedSubscriptionRuleSet]) throws -> Data {
            var settings = RoutingSettings.defaults
            settings.policyGroups = groups
            settings.blockAds = false
            return try ConfigGenerator.generate(ConfigInput(
                nodes: [node], selectedNodeID: node.id,
                runtime: RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: String(repeating: "s", count: 32)),
                routing: RoutingConfiguration(settings: settings, ruleSets: builtin, subscriptionRules: rules,
                                              subscriptionRuleSets: ruleSets, matchTarget: "漏网之鱼"),
                enabledModes: [.tun, .systemProxy], outboundMode: .rule
            ))
        }

        let before = await service.prepareForConfiguration(providers: providers, sourceID: sourceID)
        XCTAssertEqual(before.prepared.count, providers.count)
        XCTAssertTrue(before.prepared.values.allSatisfy(\.isPlaceholder))
        let placeholderConfig = try generate(before.prepared)
        let check = try await SingBoxProcess(binaryURL: singBoxURL).check(config: placeholderConfig)
        XCTAssertEqual(check.exitCode, 0, check.stderr)
        let whitelist = HelperConfigWhitelist.validate(placeholderConfig, allowedRuleSetDirectory: directory.path)
        XCTAssertTrue(whitelist.ok, whitelist.reason ?? "")

        let downloaded = await service.refresh(providers: providers, sourceID: sourceID, force: false)
        XCTAssertEqual(downloaded.updated.count, providers.count, "\(downloaded.warnings)")
        let after = await service.prepareForConfiguration(providers: providers, sourceID: sourceID)
        XCTAssertTrue(after.prepared.values.allSatisfy { !$0.isPlaceholder })
        let downloadedConfig = try generate(after.prepared)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: downloadedConfig) as? NSDictionary,
            try JSONSerialization.jsonObject(with: placeholderConfig) as? NSDictionary
        )
    }

    // MARK: - 内核校验

    func testFullConfigPassesBundledCoreCheck() async throws {
        for modes in [Set<ProxyMode>([.tun, .systemProxy]), [.systemProxy]] {
            var settings = RoutingSettings.defaults
            settings.policyGroups = groups
            settings.blockAds = true
            let input = ConfigInput(
                nodes: [node], selectedNodeID: node.id,
                runtime: RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: String(repeating: "s", count: 32)),
                routing: RoutingConfiguration(settings: settings, ruleSets: builtin, subscriptionRules: rules,
                                              subscriptionRuleSets: prepared, matchTarget: "漏网之鱼"),
                enabledModes: modes, outboundMode: .rule
            )
            let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: ConfigGenerator.generate(input))
            XCTAssertEqual(result.exitCode, 0, "\(modes)：\(result.stderr)")
        }
    }
}
