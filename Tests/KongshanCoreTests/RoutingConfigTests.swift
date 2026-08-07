import Foundation
import XCTest
@testable import KongshanCore

final class RoutingConfigTests: XCTestCase {
    func testGeneratesPrioritizedRouteRulesAndLocalRuleSets() throws {
        let rules = [
            CustomRouteRule(order: 4, type: .processName, value: "backup", action: .proxy, proxyGroup: "手动选择"),
            CustomRouteRule(order: 0, type: .domainSuffix, value: "example.com", action: .direct),
            CustomRouteRule(order: 2, type: .domain, value: "blocked.example", action: .reject),
            CustomRouteRule(order: 1, type: .domainKeyword, value: "video", action: .proxy, proxyGroup: "自动选择"),
            CustomRouteRule(order: 3, type: .ipCIDR, value: "203.0.113.0/24", action: .direct),
            CustomRouteRule(order: 5, enabled: false, type: .domain, value: "disabled.example", action: .reject)
        ]
        let settings = RoutingSettings(
            customRules: rules,
            bypassDomains: ["localhost", "*.local", ".internal"],
            bypassCIDRs: ["192.168.0.0/16"],
            blockAds: true
        )

        let root = try json(try ConfigGenerator.generate(input(
            settings: settings,
            ruleSets: PreparedRuleSets(
                geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                ads: URL(fileURLWithPath: "/tmp/geosite-category-ads-all.srs")
            )
        )))
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let routeRules = try XCTUnwrap(route["rules"] as? [[String: Any]])

        // 规则模式固定前置一条 sniff：SOCKS 客户端可能只送 IP，不嗅探则域名规则落空。
        XCTAssertEqual(routeRules.count, 10)
        XCTAssertEqual(routeRules[0]["action"] as? String, "sniff")
        assertRule(routeRules[1], field: "domain_suffix", value: "example.com", outbound: "direct")
        assertRule(routeRules[2], field: "domain_keyword", value: "video", outbound: "自动选择")
        assertRule(routeRules[3], field: "domain", value: "blocked.example", outbound: "reject")
        assertRule(routeRules[4], field: "ip_cidr", value: "203.0.113.0/24", outbound: "direct")
        assertRule(routeRules[5], field: "process_name", value: "backup", outbound: "手动选择")
        XCTAssertFalse(routeRules.contains { ($0["domain"] as? [String])?.contains("disabled.example") == true })

        XCTAssertEqual(routeRules[6]["domain"] as? [String], ["localhost"])
        XCTAssertEqual(routeRules[6]["domain_suffix"] as? [String], ["local", "internal"])
        XCTAssertEqual(routeRules[6]["ip_cidr"] as? [String], ["192.168.0.0/16"])
        XCTAssertEqual(routeRules[6]["outbound"] as? String, "direct")
        XCTAssertEqual(routeRules[7]["ip_is_private"] as? Bool, true)
        XCTAssertEqual(routeRules[7]["outbound"] as? String, "direct")
        XCTAssertEqual(routeRules[8]["rule_set"] as? String, "geosite-category-ads-all")
        XCTAssertEqual(routeRules[8]["outbound"] as? String, "reject")
        XCTAssertEqual(routeRules[9]["rule_set"] as? [String], ["geosite-cn", "geoip-cn"])
        XCTAssertEqual(routeRules[9]["outbound"] as? String, "direct")
        XCTAssertTrue(routeRules.dropFirst().allSatisfy { $0["action"] as? String == "route" })
        XCTAssertEqual(route["final"] as? String, "手动选择")

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.map { $0["tag"] as? String }, ["geosite-cn", "geoip-cn", "geosite-category-ads-all"])
        XCTAssertTrue(ruleSets.allSatisfy { $0["type"] as? String == "local" && $0["format"] as? String == "binary" })
        XCTAssertEqual(ruleSets[0]["path"] as? String, "/tmp/geosite-cn.srs")
        XCTAssertEqual(ruleSets[1]["path"] as? String, "/tmp/geoip-cn.srs")
        XCTAssertEqual(ruleSets[2]["path"] as? String, "/tmp/geosite-category-ads-all.srs")

        XCTAssertEqual(settings.bypassDomains, ["localhost", "*.local", ".internal"])
        // 回环项由 systemProxyBypassEntries 无条件补齐（用户删不掉），用户自定义项排在后面。
        XCTAssertEqual(
            settings.systemProxyBypassEntries,
            ["127.0.0.1", "localhost", "::1", "*.local", ".internal", "192.168.0.0/16"]
        )
    }

    func testOmitsAdsRuleAndRuleSetWhenBlockingIsDisabled() throws {
        let root = try json(try ConfigGenerator.generate(input(
            settings: RoutingSettings(customRules: [], bypassDomains: [], bypassCIDRs: [], blockAds: false),
            ruleSets: PreparedRuleSets(
                geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                ads: nil
            )
        )))
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let routeRules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])

        XCTAssertEqual(routeRules.count, 3)
        XCTAssertEqual(routeRules[0]["action"] as? String, "sniff")
        XCTAssertFalse(routeRules.contains { $0["rule_set"] as? String == "geosite-category-ads-all" })
        XCTAssertEqual(ruleSets.map { $0["tag"] as? String }, ["geosite-cn", "geoip-cn"])
    }

    func testRequiresAdsRuleSetWhenBlockingIsEnabled() {
        let settings = RoutingSettings(customRules: [], bypassDomains: [], bypassCIDRs: [], blockAds: true)
        let ruleSets = PreparedRuleSets(
            geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
            geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
            ads: nil
        )

        XCTAssertThrowsError(try ConfigGenerator.generate(input(settings: settings, ruleSets: ruleSets))) { error in
            XCTAssertEqual(error as? ConfigGenerationError, .missingRuleSet("geosite-category-ads-all"))
        }
    }

    func testGeneratedRoutingConfigPassesBundledSingBoxCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ruleSets = try await compileRuleSets(in: directory)
        let config = try ConfigGenerator.generate(input(
            settings: RoutingSettings.defaults,
            ruleSets: ruleSets
        ))
        let core = SingBoxProcess(binaryURL: singBoxURL)

        let result = try await core.check(config: config)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    private func input(settings: RoutingSettings, ruleSets: PreparedRuleSets) -> ConfigInput {
        let node = ProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
            name: "test",
            protocolType: .shadowsocks,
            server: "1.1.1.1",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
        return ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "runtime-secret"),
            routing: RoutingConfiguration(settings: settings, ruleSets: ruleSets)
        )
    }

    private func assertRule(
        _ rule: [String: Any],
        field: String,
        value: String,
        outbound: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(rule[field] as? [String], [value], file: file, line: line)
        XCTAssertEqual(rule["action"] as? String, "route", file: file, line: line)
        XCTAssertEqual(rule["outbound"] as? String, outbound, file: file, line: line)
    }

    private func compileRuleSets(in directory: URL) async throws -> PreparedRuleSets {
        let source = directory.appending(path: "source.json")
        try Data(#"{"version":3,"rules":[{"domain_suffix":["example.com"]}]}"#.utf8).write(to: source)

        func compile(_ name: String) async throws -> URL {
            let output = directory.appending(path: "\(name).srs")
            let result = try await ProcessRunner.run(
                executable: singBoxURL,
                arguments: ["rule-set", "compile", source.path, "-o", output.path],
                timeout: 10
            )
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            return output
        }

        return try await PreparedRuleSets(
            geositeCN: compile("geosite-cn"),
            geoipCN: compile("geoip-cn"),
            ads: compile("geosite-category-ads-all")
        )
    }

    private var singBoxURL: URL {
        packageRoot.appending(path: "Vendor/sing-box/sing-box")
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension RoutingConfigTests {
    /// 三种出站模式生成的配置都必须能通过打包内核校验。
    func testAllOutboundModesPassBundledCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)
        let core = SingBoxProcess(binaryURL: singBoxURL)
        let node = ProxyNode(
            name: "n",
            protocolType: .shadowsocks,
            server: "example.com",
            port: 443,
            password: "p",
            method: "aes-128-gcm"
        )

        for mode in OutboundMode.allCases {
            let config = try ConfigGenerator.generate(ConfigInput(
                nodes: [node],
                selectedNodeID: node.id,
                runtime: RuntimeParameters(mixedPort: 17_890, clashPort: 17_891, secret: "s"),
                routing: RoutingConfiguration(settings: .defaults, ruleSets: ruleSets),
                outboundMode: mode
            ))
            let result = try await core.check(config: config)
            XCTAssertEqual(result.exitCode, 0, "\(mode.displayName): \(result.stderr)")

            let root = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: config) as? [String: Any]
            )
            let route = try XCTUnwrap(root["route"] as? [String: Any])
            switch mode {
            case .rule:
                XCTAssertFalse((route["rules"] as? [[String: Any]] ?? []).isEmpty)
            case .global:
                XCTAssertEqual(route["final"] as? String, "手动选择")
                XCTAssertTrue((route["rules"] as? [[String: Any]] ?? []).isEmpty)
            case .direct:
                XCTAssertEqual(route["final"] as? String, "direct")
                XCTAssertTrue((route["rules"] as? [[String: Any]] ?? []).isEmpty)
            }
        }
    }
}

extension RoutingConfigTests {
    func testForcedProxyDomainAndIPPrecedeBypassAndBuiltInDirectRules() throws {
        var settings = RoutingSettings.defaults
        settings.customRules = [
            CustomRouteRule(
                order: 0,
                type: .domainSuffix,
                value: "download.cn",
                action: .proxy,
                proxyGroup: "stale-group"
            ),
            CustomRouteRule(
                order: 1,
                type: .ipCIDR,
                value: "10.20.30.40",
                action: .proxy,
                proxyGroup: "手动选择"
            )
        ]
        let root = try json(try ConfigGenerator.generate(input(
            settings: settings,
            ruleSets: PreparedRuleSets(
                geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                ads: nil
            )
        )))
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])

        XCTAssertEqual(rules[0]["action"] as? String, "sniff")
        assertRule(rules[1], field: "domain_suffix", value: "download.cn", outbound: "手动选择")
        assertRule(rules[2], field: "ip_cidr", value: "10.20.30.40/32", outbound: "手动选择")
        XCTAssertEqual(rules[3]["outbound"] as? String, "direct")
        XCTAssertEqual(rules[4]["ip_is_private"] as? Bool, true)
    }

    func testProcessRuleCanTargetNodeTagAndStaleTargetFallsBackSafely() throws {
        let node = ProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000088")!,
            name: "指定节点",
            protocolType: .shadowsocks,
            server: "example.com",
            port: 443,
            password: "p",
            method: "aes-128-gcm"
        )
        let nodeTag = ConfigGenerator.outboundTag(for: node)
        var settings = RoutingSettings.defaults
        settings.customRules = [
            CustomRouteRule(order: 0, type: .processName, value: "Game.app", action: .proxy, proxyGroup: nodeTag),
            CustomRouteRule(order: 1, type: .processName, value: "Old.app", action: .proxy, proxyGroup: "node-missing")
        ]
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 17_900, clashPort: 17_901, secret: "s"),
            routing: RoutingConfiguration(
                settings: settings,
                ruleSets: PreparedRuleSets(
                    geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                    geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                    ads: nil
                )
            )
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])

        XCTAssertEqual(rules[1]["outbound"] as? String, nodeTag)
        XCTAssertEqual(rules[2]["outbound"] as? String, "手动选择")
    }

    /// 自定义策略组要在配置里生成对应出站，且能被自定义规则引用。
    func testCustomPolicyGroupsBecomeOutboundsAndPassCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        var settings = RoutingSettings.defaults
        settings.policyGroups = [
            PolicyGroup(name: "流媒体", kind: .selector),
            PolicyGroup(name: "AI", kind: .urltest)
        ]
        settings.customRules = [
            CustomRouteRule(order: 0, type: .domainSuffix, value: "netflix.com", action: .proxy, proxyGroup: "流媒体"),
            CustomRouteRule(order: 1, type: .domainSuffix, value: "openai.com", action: .proxy, proxyGroup: "AI")
        ]

        let node = ProxyNode(
            name: "n", protocolType: .shadowsocks, server: "example.com", port: 443,
            password: "p", method: "aes-128-gcm"
        )
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 17_900, clashPort: 17_901, secret: "s"),
            routing: RoutingConfiguration(settings: settings, ruleSets: ruleSets)
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let tags = outbounds.compactMap { $0["tag"] as? String }
        XCTAssertTrue(tags.contains("流媒体"))
        XCTAssertTrue(tags.contains("AI"))
        XCTAssertEqual(outbounds.first { $0["tag"] as? String == "AI" }?["type"] as? String, "urltest")

        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["action"] as? String, "sniff")
        XCTAssertEqual(rules.dropFirst().first?["outbound"] as? String, "流媒体")

        let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testReservedAndDuplicatePolicyGroupNamesAreRejected() {
        var settings = RoutingSettings.defaults
        settings.policyGroups = [PolicyGroup(name: "自动选择")]
        XCTAssertThrowsError(try settings.validated())

        settings.policyGroups = [PolicyGroup(name: "A"), PolicyGroup(name: "A")]
        XCTAssertThrowsError(try settings.validated())

        settings.policyGroups = [PolicyGroup(name: "A"), PolicyGroup(name: "B")]
        XCTAssertNoThrow(try settings.validated())
    }
}

extension RoutingConfigTests {
    func testSubscriptionRulesParseAndEnterConfigWithUnresolvableTargetsDropped() async throws {
        XCTAssertEqual(
            SubscriptionRule.parse("DOMAIN-SUFFIX,google.com,Proxies"),
            SubscriptionRule(type: .domainSuffix, value: "google.com", target: "Proxies")
        )
        XCTAssertEqual(
            SubscriptionRule.parse("IP-CIDR,1.1.1.1/32,DIRECT,no-resolve"),
            SubscriptionRule(type: .ipCIDR, value: "1.1.1.1/32", target: "DIRECT")
        )
        // 不支持的类型与非法值都跳过
        XCTAssertNil(SubscriptionRule.parse("GEOIP,CN,DIRECT"))
        XCTAssertNil(SubscriptionRule.parse("MATCH,Proxies"))
        XCTAssertNil(SubscriptionRule.parse("IP-CIDR,not-a-cidr,DIRECT"))

        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        var settings = RoutingSettings.defaults
        settings.policyGroups = [PolicyGroup(name: "流媒体")]
        let node = ProxyNode(
            name: "n", protocolType: .shadowsocks, server: "example.com", port: 443,
            password: "p", method: "aes-128-gcm"
        )
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 17_910, clashPort: 17_911, secret: "s"),
            routing: RoutingConfiguration(
                settings: settings,
                ruleSets: ruleSets,
                subscriptionRules: [
                    SubscriptionRule(type: .domainSuffix, value: "netflix.com", target: "流媒体"),
                    SubscriptionRule(type: .domain, value: "ad.example", target: "REJECT"),
                    SubscriptionRule(type: .domainSuffix, value: "cn.example", target: "DIRECT"),
                    // 目标组不存在，必须被丢弃，否则内核校验会失败
                    SubscriptionRule(type: .domainSuffix, value: "ghost.example", target: "NotExisting")
                ]
            )
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let outbounds = rules.compactMap { $0["outbound"] as? String }
        XCTAssertTrue(outbounds.contains("流媒体"))
        XCTAssertTrue(outbounds.contains("reject"))
        XCTAssertFalse(rules.contains { ($0["domain_suffix"] as? [String])?.contains("ghost.example") == true })

        let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }
}

extension RoutingConfigTests {
    /// 策略组各自记住的节点要写进配置的 default，否则内核重启后全部回退。
    func testGroupDefaultsRestoreRememberedSelectionsWithFallback() throws {
        var settings = RoutingSettings.defaults
        settings.policyGroups = [PolicyGroup(name: "流媒体", kind: .selector)]

        let a = ProxyNode(
            name: "a", protocolType: .shadowsocks, server: "a.com", port: 443,
            password: "p", method: "aes-128-gcm"
        )
        let b = ProxyNode(
            name: "b", protocolType: .shadowsocks, server: "b.com", port: 443,
            password: "p", method: "aes-128-gcm"
        )
        let manual = ProxyNode(
            name: "自建机", protocolType: .hysteria2, server: "m.com", port: 443,
            password: "p"
        )
        let ruleSets = PreparedRuleSets(
            geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
            geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
            ads: nil
        )

        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [a, b, manual],
            selectedNodeID: a.id,
            runtime: RuntimeParameters(mixedPort: 17_910, clashPort: 17_911, secret: "s"),
            routing: RoutingConfiguration(settings: settings, ruleSets: ruleSets),
            groupDefaults: [
                "流媒体": ConfigGenerator.outboundTag(for: b),
                "自建": ConfigGenerator.outboundTag(for: manual),
                "不存在的组": "node-ffffffff-0000-0000-0000-000000000000"
            ]
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        func outbound(_ tag: String) -> [String: Any]? {
            outbounds.first { $0["tag"] as? String == tag }
        }

        XCTAssertEqual(outbound("流媒体")?["default"] as? String, ConfigGenerator.outboundTag(for: b))
        XCTAssertEqual(outbound("自建")?["default"] as? String, ConfigGenerator.outboundTag(for: manual))
        // 记住的节点已不存在 → 回退全局选中节点，而不是引用幽灵 tag 导致内核拒启。
        let stale = try ConfigGenerator.generate(ConfigInput(
            nodes: [a, b],
            selectedNodeID: a.id,
            runtime: RuntimeParameters(mixedPort: 17_912, clashPort: 17_913, secret: "s"),
            routing: RoutingConfiguration(settings: settings, ruleSets: ruleSets),
            groupDefaults: ["流媒体": "node-ffffffff-0000-0000-0000-000000000000"]
        ))
        let staleRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: stale) as? [String: Any])
        let staleOutbounds = try XCTUnwrap(staleRoot["outbounds"] as? [[String: Any]])
        XCTAssertEqual(
            staleOutbounds.first { $0["tag"] as? String == "流媒体" }?["default"] as? String,
            ConfigGenerator.outboundTag(for: a)
        )
    }
}

extension RoutingConfigTests {
    /// 配置自带策略组（带真实成员：节点名 / 子组 / DIRECT）应解析成对应出站 tag，
    /// 生成的配置能通过打包内核校验；空成员回退全部节点。
    func testConfigPolicyGroupMembersResolveAndPassCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        let hk = ProxyNode(name: "香港 01", protocolType: .shadowsocks, server: "a.com", port: 443, password: "p", method: "aes-128-gcm")
        let jp = ProxyNode(name: "日本 01", protocolType: .shadowsocks, server: "b.com", port: 443, password: "p", method: "aes-128-gcm")

        var settings = RoutingSettings.defaults
        settings.policyGroups = [
            PolicyGroup(name: "香港", kind: .selector, members: ["香港 01"]),
            PolicyGroup(name: "节点选择", kind: .selector, members: ["香港", "日本 01", "DIRECT"])
        ]

        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [hk, jp],
            selectedNodeID: hk.id,
            runtime: RuntimeParameters(mixedPort: 18_900, clashPort: 18_901, secret: "s"),
            routing: RoutingConfiguration(settings: settings, ruleSets: ruleSets)
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        func outbound(_ tag: String) -> [String: Any]? { outbounds.first { $0["tag"] as? String == tag } }

        // 「香港」只含香港节点
        XCTAssertEqual(outbound("香港")?["outbounds"] as? [String], [ConfigGenerator.outboundTag(for: hk)])
        // 「节点选择」= 子组「香港」+ 日本节点 + direct
        XCTAssertEqual(
            outbound("节点选择")?["outbounds"] as? [String],
            ["香港", ConfigGenerator.outboundTag(for: jp), "direct"]
        )

        let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    /// 机场"轮辐"结构（只用配置自带策略组）：被 ≥2 个策略默认引用、自身首选直连的主组，
    /// 其默认应改为指向「真实节点」(App 当前选中的节点)而非机场的绕过代理；不生成内置手动/自动选择；
    /// 指向主组的策略(国外媒体/兜底)自然跟随不被强改；首选直连的服务组(微软)保持直连；final 走主组。
    /// 这道题就是用户"开了代理没效果、选节点不生效"的最小复现。
    func testHubMasterDefaultsToSelectedNodeAndBypassPreserved() throws {
        let jp = ProxyNode(name: "JP 01", protocolType: .shadowsocks, server: "a.com", port: 443, password: "p", method: "aes-128-gcm")
        let jpTag = ConfigGenerator.outboundTag(for: jp)
        var settings = RoutingSettings.defaults
        settings.blockAds = false
        settings.policyGroups = [
            PolicyGroup(name: "绕过代理", kind: .selector, members: ["DIRECT"]),
            PolicyGroup(name: "机场主组", kind: .selector, members: ["绕过代理", "JP 01"]),   // 主组自身首选直连
            PolicyGroup(name: "国外媒体", kind: .selector, members: ["机场主组", "绕过代理"]),
            PolicyGroup(name: "兜底", kind: .selector, members: ["机场主组", "绕过代理"]),
            PolicyGroup(name: "微软服务", kind: .selector, members: ["绕过代理", "机场主组"])  // 服务组首选直连
        ]
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [jp],
            selectedNodeID: jp.id,
            runtime: RuntimeParameters(mixedPort: 18_902, clashPort: 18_903, secret: "s"),
            routing: RoutingConfiguration(settings: settings, ruleSets: PreparedRuleSets(
                geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                ads: nil))
        ))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        func outbound(_ tag: String) -> [String: Any]? { outbounds.first { $0["tag"] as? String == tag } }

        // 有机场策略组时不生成内置手动/自动选择
        XCTAssertNil(outbound("手动选择"))
        XCTAssertNil(outbound("自动选择"))
        // 主组默认指向真实节点（App 当前选中的 JP 01），而非机场的「绕过代理」直连
        XCTAssertEqual(outbound("机场主组")?["default"] as? String, jpTag)
        // 指向主组的策略保持默认主组，未被强改（用户在主组挑节点后自然贯穿）
        XCTAssertEqual(outbound("国外媒体")?["default"] as? String, "机场主组")
        XCTAssertEqual(outbound("兜底")?["default"] as? String, "机场主组")
        // 首选直连的服务组保持机场意图（指向直连包装组），不被拉去代理
        XCTAssertEqual(outbound("微软服务")?["default"] as? String, "绕过代理")
        // final 走主组（顺带消除 urltest 作 final 导致的出站 IP 跳动）
        XCTAssertEqual((root["route"] as? [String: Any])?["final"] as? String, "机场主组")
    }

    /// 成员全部解析不到时回退全部节点，绝不产出空组（空组会让内核校验失败）。
    func testConfigPolicyGroupWithUnresolvableMembersFallsBackToAllNodes() throws {
        let node = ProxyNode(name: "n", protocolType: .shadowsocks, server: "a.com", port: 443, password: "p", method: "aes-128-gcm")
        var settings = RoutingSettings.defaults
        settings.policyGroups = [PolicyGroup(name: "空组", kind: .selector, members: ["不存在的节点"])]

        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 18_902, clashPort: 18_903, secret: "s"),
            routing: RoutingConfiguration(
                settings: settings,
                ruleSets: PreparedRuleSets(
                    geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                    geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                    ads: nil
                )
            )
        ))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(
            outbounds.first { $0["tag"] as? String == "空组" }?["outbounds"] as? [String],
            [ConfigGenerator.outboundTag(for: node)]
        )
    }
}

extension RoutingConfigTests {
    /// 订阅规则合并：连续的同类型同出站并成一条（值进数组），换类型/换出站就断开——
    /// 匹配顺序（首个命中生效）与合并前一致。几千条能压到一两百条，配置随之瘦身。
    func testConsecutiveSubscriptionRulesMergePreservingOrder() {
        let available: Set<String> = ["Proxies", "Netflix"]
        let rules = [
            SubscriptionRule(type: .domainSuffix, value: "a.com", target: "Proxies"),
            SubscriptionRule(type: .domainSuffix, value: "b.com", target: "Proxies"),
            SubscriptionRule(type: .domainSuffix, value: "n.com", target: "Netflix"),  // 换出站→断开
            SubscriptionRule(type: .ipCIDR, value: "1.1.1.0/24", target: "Netflix"),   // 换类型→断开
            SubscriptionRule(type: .domainSuffix, value: "d.com", target: "Proxies"),
            SubscriptionRule(type: .domainSuffix, value: "x.com", target: "缺失组"),    // 目标不存在→丢弃
        ]

        let merged = ConfigGenerator.mergedSubscriptionRules(rules, available: available)

        XCTAssertEqual(merged.count, 4)
        XCTAssertEqual(merged[0]["domain_suffix"] as? [String], ["a.com", "b.com"])
        XCTAssertEqual(merged[0]["outbound"] as? String, "Proxies")
        XCTAssertEqual(merged[1]["domain_suffix"] as? [String], ["n.com"])
        XCTAssertEqual(merged[1]["outbound"] as? String, "Netflix")
        XCTAssertEqual(merged[2]["ip_cidr"] as? [String], ["1.1.1.0/24"])
        XCTAssertEqual(merged[3]["domain_suffix"] as? [String], ["d.com"])
        XCTAssertTrue(merged.allSatisfy { $0["action"] as? String == "route" })
    }
}
