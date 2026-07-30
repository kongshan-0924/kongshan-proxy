import HelperProtocol
import Foundation
import XCTest
@testable import KongshanCore

final class DNSConfigTests: XCTestCase {
    func testDefaultsAndValidationRejectUnsafeDoHURLs() throws {
        XCTAssertEqual(DNSSettings.defaults.domesticDoH, "https://223.5.5.5/dns-query")
        XCTAssertEqual(DNSSettings.defaults.remoteDoH, "https://8.8.8.8/dns-query")
        XCTAssertEqual(try DNSSettings.defaults.validated(), .defaults)

        for invalid in [
            "http://223.5.5.5/dns-query",
            "https:///dns-query",
            "https://user:password@dns.example/dns-query",
            "https://dns.example",
            "https://dns.example/dns-query#fragment"
        ] {
            XCTAssertThrowsError(try DNSSettings(
                domesticDoH: invalid,
                remoteDoH: DNSSettings.defaults.remoteDoH
            ).validated(), "Expected invalid URL to fail: \(invalid)")
        }
    }

    func testGeneratesDualDoHWithChinaRuleAndDirectBootstrap() throws {
        let root = try json(try ConfigGenerator.generate(input()))
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])

        // 引导解析器无条件存在，即使国内 DoH 已经是 IP（不需要被引导解析）也一样：
        // 它的职责不止"解析 DoH 主机名"，更重要的是给 route.default_domain_resolver
        // 提供一条**无连接**的解析通道，见下面 default_domain_resolver 的断言。
        XCTAssertEqual(servers.map { $0["tag"] as? String }, ["dns-bootstrap", "dns-cn", "dns-remote"])
        XCTAssertEqual(servers[0]["type"] as? String, "udp")
        XCTAssertEqual(servers[0]["server"] as? String, "223.5.5.5")
        XCTAssertEqual(servers[0]["server_port"] as? Int, 53)
        XCTAssertNil(servers[0]["detour"])
        assertDoH(
            servers[1],
            tag: "dns-cn",
            server: "223.5.5.5",
            path: "/dns-query",
            detour: nil
        )
        assertDoH(
            servers[2],
            tag: "dns-remote",
            server: "8.8.8.8",
            path: "/dns-query",
            detour: "手动选择"
        )
        XCTAssertNil(dns["fakeip"])
        XCTAssertEqual(dns["final"] as? String, "dns-remote")

        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(dnsRules.count, 1)
        XCTAssertEqual(dnsRules[0]["rule_set"] as? String, "geosite-cn")
        XCTAssertEqual(dnsRules[0]["action"] as? String, "route")
        XCTAssertEqual(dnsRules[0]["server"] as? String, "dns-cn")

        // **必须是无连接的 dns-bootstrap，不能是 DoH。**
        // default_domain_resolver 负责解析出站节点自己的域名。DoH 是长连接，被路由器 NAT
        // 悄悄回收后 sing-box 察觉不到，会往死 socket 里写并卡满 10 秒——那一刻整个代理
        // 停摆，不只是某个网站打不开。真机实证：每 ~16 分钟一簇 10.0s
        // `context deadline exceeded`，节点域名与国内域名同时中招；
        // 同一时刻 curl 新建连接打同一 DoH 端点 20/20 成功，证明是连接陈旧而非服务器故障。
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-bootstrap")
    }

    /// 用户把国内 DoH 换成别的 IP 时，引导解析器要跟着走同一家，
    /// 不能硬钉 223.5.5.5——否则用户以为换掉了阿里，实际节点域名还在问阿里。
    func testBootstrapFollowsCustomDomesticResolverIP() throws {
        let settings = DNSSettings(
            domesticDoH: "https://119.29.29.29/dns-query",
            remoteDoH: DNSSettings.defaults.remoteDoH
        )
        let root = try json(try ConfigGenerator.generate(input(dnsSettings: settings)))
        let servers = try XCTUnwrap((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]])

        XCTAssertEqual(servers[0]["tag"] as? String, "dns-bootstrap")
        XCTAssertEqual(servers[0]["type"] as? String, "udp")
        XCTAssertEqual(servers[0]["server"] as? String, "119.29.29.29")
    }

    func testCustomDomainDoHUsesFiniteDirectBootstrapChain() throws {
        let settings = DNSSettings(
            domesticDoH: "https://dns.alidns.com:8443/custom-query?profile=mac",
            remoteDoH: "https://dns.google/dns-query"
        )
        let root = try json(try ConfigGenerator.generate(input(dnsSettings: settings)))
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])

        XCTAssertEqual(servers.map { $0["tag"] as? String }, ["dns-bootstrap", "dns-cn", "dns-remote"])
        XCTAssertEqual(servers[0]["type"] as? String, "udp")
        XCTAssertEqual(servers[0]["server"] as? String, "223.5.5.5")
        XCTAssertNil(servers[0]["detour"])
        XCTAssertEqual(servers[1]["server"] as? String, "dns.alidns.com")
        XCTAssertEqual(servers[1]["server_port"] as? Int, 8443)
        XCTAssertEqual(servers[1]["path"] as? String, "/custom-query?profile=mac")
        XCTAssertEqual(servers[1]["domain_resolver"] as? String, "dns-bootstrap")
        XCTAssertEqual(servers[2]["server"] as? String, "dns.google")
        XCTAssertEqual(servers[2]["domain_resolver"] as? String, "dns-cn")
    }

    func testTUNPrependsDNSHijackWithoutChangingBusinessRuleOrder() throws {
        let systemRoot = try json(try ConfigGenerator.generate(input(proxyMode: .systemProxy)))
        let systemRoute = try XCTUnwrap(systemRoot["route"] as? [String: Any])
        let systemRules = try XCTUnwrap(systemRoute["rules"] as? [[String: Any]])
        // 规则模式统一前置 sniff（含 mixed），hijack-dns 仍然只属于 TUN。
        XCTAssertEqual(systemRules[0]["action"] as? String, "sniff")
        XCTAssertEqual(systemRules[1]["domain_suffix"] as? [String], ["custom.example"])
        XCTAssertFalse(systemRules.contains { $0["action"] as? String == "hijack-dns" })

        let tunRoot = try json(try ConfigGenerator.generate(input(proxyMode: .tun)))
        let tunRoute = try XCTUnwrap(tunRoot["route"] as? [String: Any])
        let tunRules = try XCTUnwrap(tunRoute["rules"] as? [[String: Any]])
        XCTAssertEqual(tunRules[0]["action"] as? String, "sniff")
        XCTAssertEqual(tunRules[1]["protocol"] as? String, "dns")
        XCTAssertEqual(tunRules[1]["action"] as? String, "hijack-dns")
        // 240/4 与物理网关/订阅的 198.18 Fake-IP 隔离，且必须优先固定走代理。
        XCTAssertEqual(tunRules[2]["ip_cidr"] as? [String], ["240.0.0.0/4"])
        XCTAssertEqual(tunRules[2]["outbound"] as? String, "手动选择")
        // 业务规则相对顺序不变，只整体后移一位。
        XCTAssertEqual(tunRules[3]["domain_suffix"] as? [String], ["custom.example"])
        XCTAssertEqual(tunRules[4]["domain"] as? [String], ["localhost"])
        XCTAssertEqual(tunRules[5]["ip_is_private"] as? Bool, true)
        XCTAssertEqual(tunRules[6]["rule_set"] as? [String], ["geosite-cn", "geoip-cn"])
    }

    func testSystemAndTUNDefaultAndCustomDNSPassBundledCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)
        let routing = RoutingConfiguration(settings: routingSettings, ruleSets: ruleSets)
        let custom = DNSSettings(
            domesticDoH: "https://dns.alidns.com/dns-query",
            remoteDoH: "https://dns.google/dns-query"
        )
        let core = SingBoxProcess(binaryURL: singBoxURL)

        for (mode, dnsSettings) in [
            (ProxyMode.systemProxy, DNSSettings.defaults),
            (.tun, .defaults),
            (.systemProxy, custom),
            (.tun, custom)
        ] {
            let config = try ConfigGenerator.generate(ConfigInput(
                nodes: [node],
                selectedNodeID: node.id,
                runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "memory-only"),
                routing: routing,
                proxyMode: mode,
                dnsSettings: dnsSettings
            ))
            let result = try await core.check(config: config)
            XCTAssertEqual(result.exitCode, 0, "mode=\(mode), dns=\(dnsSettings): \(result.stderr)")
        }
    }

    func testDefaultDNSCoreStartsAndServesClashAPI() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)
        let runtime = try runtimeParameters()
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [ProxyNode(
                name: "local-node",
                protocolType: .shadowsocks,
                server: "127.0.0.1",
                port: 9,
                password: "secret",
                method: "aes-128-gcm"
            )],
            selectedNodeID: nil,
            runtime: runtime,
            routing: RoutingConfiguration(settings: .defaults, ruleSets: ruleSets)
        ))
        let logs = DNSLogCollector()
        let core = SingBoxProcess(binaryURL: singBoxURL) { line in
            Task { await logs.append(line.text) }
        }
        try await core.start(config: config)

        let client = ClashAPIClient(
            controller: URL(string: "http://127.0.0.1:\(runtime.clashPort)")!,
            secret: runtime.secret
        )
        var healthy = false
        for _ in 0..<30 {
            if (try? await client.health()) != nil {
                healthy = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let capturedLogs = await logs.value()
        await core.stop()
        XCTAssertTrue(healthy, capturedLogs)
    }

    private var node: ProxyNode {
        ProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D5")!,
            name: "domain-node",
            protocolType: .shadowsocks,
            server: "proxy.example",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
    }

    private var routingSettings: RoutingSettings {
        RoutingSettings(
            customRules: [
                CustomRouteRule(
                    order: 0,
                    type: .domainSuffix,
                    value: "custom.example",
                    action: .proxy,
                    proxyGroup: "手动选择"
                )
            ],
            bypassDomains: ["localhost"],
            bypassCIDRs: ["192.168.0.0/16"],
            blockAds: false
        )
    }

    // MARK: - 内网 DNS 分流

    private var lanSnapshot: LANResolverSnapshot {
        LANResolverSnapshot(servers: ["172.16.16.7"], searchDomains: ["corp.example.com"])
    }

    /// 内网规则**必须排在 geosite-cn 与 fakeip 之前**。
    /// 真机遇到的 AD 域是个 `.com`：既不命中 geosite-cn，也就必然掉进 fakeip，
    /// 拿到 240.x 假 IP，而假 IP 整段被路由进代理出口 → 内网设备一直加载。
    func testLANRuleComesBeforeChinaAndFakeIPRules() throws {
        let root = try json(try ConfigGenerator.generate(
            input(proxyMode: .tun, lanResolver: lanSnapshot)
        ))
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])

        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let lan = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-lan" })
        XCTAssertEqual(lan["type"] as? String, "udp", "内网 DNS 走 UDP：无连接，不会像 DoH 那样卡死")
        XCTAssertEqual(lan["server"] as? String, "172.16.16.7")
        XCTAssertEqual(lan["server_port"] as? Int, 53)
        XCTAssertNil(lan["detour"], "内网 DNS 必须直连，绝不能绕经代理出口")

        let rules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["server"] as? String, "dns-lan", "内网规则必须是第一条")
        XCTAssertEqual(rules.first?["domain_suffix"] as? [String], ["corp.example.com"])

        let lanIndex = try XCTUnwrap(rules.firstIndex { $0["server"] as? String == "dns-lan" })
        let fakeIPIndex = try XCTUnwrap(rules.firstIndex { $0["server"] as? String == "dns-fakeip" })
        let cnIndex = try XCTUnwrap(rules.firstIndex { $0["server"] as? String == "dns-cn" })
        XCTAssertLessThan(lanIndex, cnIndex)
        XCTAssertLessThan(lanIndex, fakeIPIndex)
    }

    /// DNS 解对了还不够：内网域名可能解析到 DMZ 的公网 IP，
    /// 那时按 IP 判定的私有网段规则会落空，流量还是被送进代理。
    func testLANDomainsAlsoRoutedDirect() throws {
        let root = try json(try ConfigGenerator.generate(
            input(proxyMode: .tun, lanResolver: lanSnapshot)
        ))
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let direct = try XCTUnwrap(rules.first {
            $0["outbound"] as? String == "direct" && ($0["domain_suffix"] as? [String])?.contains("corp.example.com") == true
        })
        XCTAssertEqual(direct["action"] as? String, "route")
    }

    func testNoLANServerWhenNothingDetected() throws {
        let root = try json(try ConfigGenerator.generate(input(proxyMode: .tun)))
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertNil(servers.first { $0["tag"] as? String == "dns-lan" })
        let rules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertNil(rules.first { $0["server"] as? String == "dns-lan" })
    }

    func testLANSplitCanBeTurnedOff() throws {
        var tun = TunSettings.defaults
        tun.lanDNSEnabled = false
        let root = try json(try ConfigGenerator.generate(
            input(proxyMode: .tun, tunSettings: tun, lanResolver: lanSnapshot)
        ))
        let servers = try XCTUnwrap((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]])
        XCTAssertNil(servers.first { $0["tag"] as? String == "dns-lan" })
    }

    /// 内核自己得认这份配置——`dns-lan` 的字段名/类型写错时单测照样全绿，只有 check 能拦住。
    func testLANSplitConfigPassesBundledCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        var tun = TunSettings.defaults
        tun.lanDomainSuffixes = ["ops.example.com"]
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "memory-only"),
            routing: RoutingConfiguration(settings: routingSettings, ruleSets: ruleSets),
            enabledModes: [.tun],
            tunSettings: tun,
            dnsSettings: .defaults,
            lanResolver: lanSnapshot
        ))
        let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    private func input(
        proxyMode: ProxyMode = .systemProxy,
        dnsSettings: DNSSettings = .defaults,
        tunSettings: TunSettings = .defaults,
        lanResolver: LANResolverSnapshot = .empty
    ) -> ConfigInput {
        ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "memory-only"),
            routing: RoutingConfiguration(
                settings: routingSettings,
                ruleSets: PreparedRuleSets(
                    geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                    geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                    ads: nil
                )
            ),
            enabledModes: [proxyMode],
            tunSettings: tunSettings,
            dnsSettings: dnsSettings,
            lanResolver: lanResolver
        )
    }

    private func assertDoH(
        _ value: [String: Any],
        tag: String,
        server: String,
        path: String,
        detour: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(value["type"] as? String, "https", file: file, line: line)
        XCTAssertEqual(value["tag"] as? String, tag, file: file, line: line)
        XCTAssertEqual(value["server"] as? String, server, file: file, line: line)
        XCTAssertEqual(value["path"] as? String, path, file: file, line: line)
        XCTAssertEqual(value["detour"] as? String, detour, file: file, line: line)
        XCTAssertEqual((value["tls"] as? [String: Any])?["enabled"] as? Bool, true, file: file, line: line)
        XCTAssertEqual((value["tls"] as? [String: Any])?["server_name"] as? String, server, file: file, line: line)
    }

    private func compileRuleSets(in directory: URL) async throws -> PreparedRuleSets {
        let geositeSource = directory.appending(path: "geosite-source.json")
        let geoipSource = directory.appending(path: "geoip-source.json")
        try Data(#"{"version":3,"rules":[{"domain_suffix":["cn"]}]}"#.utf8).write(to: geositeSource)
        try Data(#"{"version":3,"rules":[{"ip_cidr":["1.0.1.0/24"]}]}"#.utf8).write(to: geoipSource)

        func compile(_ source: URL, as name: String) async throws -> URL {
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
            geositeCN: compile(geositeSource, as: "geosite-cn"),
            geoipCN: compile(geoipSource, as: "geoip-cn"),
            ads: nil
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

    private func runtimeParameters() throws -> RuntimeParameters {
        let mixed = try RuntimeSecrets.availableHighPort()
        var clash = try RuntimeSecrets.availableHighPort()
        while clash == mixed { clash = try RuntimeSecrets.availableHighPort() }
        return RuntimeParameters(mixedPort: mixed, clashPort: clash, secret: try RuntimeSecrets.secret())
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor DNSLogCollector {
    private var lines: [String] = []

    func append(_ value: String) {
        lines.append(value)
    }

    func value() -> String {
        lines.joined()
    }
}

/// 内网分流配置必须能过**助手的白名单**，不只是过 sing-box 的 check。
///
/// TUN 恰恰是内网分流最需要生效的场景，而 TUN 的配置要经 root 助手投喂——
/// 白名单拒了就整条链路起不来。sing-box check 通过 ≠ 助手放行，两道关是独立的。
extension DNSConfigTests {
    func testLANSplitConfigPassesHelperWhitelist() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            // 助手白名单要求 clash_api secret ≥16 字符（真机上是 32 字节随机的 base64）。
            runtime: RuntimeParameters(
                mixedPort: 51_080,
                clashPort: 51_909,
                secret: "0123456789abcdef0123456789abcdef"
            ),
            routing: RoutingConfiguration(settings: routingSettings, ruleSets: ruleSets),
            enabledModes: [.tun],
            dnsSettings: .defaults,
            lanResolver: LANResolverSnapshot(servers: ["172.16.16.7"], searchDomains: ["corp.example.com"])
        ))

        let result = HelperConfigWhitelist.validate(config)
        XCTAssertTrue(result.ok, "助手白名单拒绝了内网分流配置：\(result.reason ?? "未给原因")")
        XCTAssertNotNil(result.sanitizedData)
    }
}
