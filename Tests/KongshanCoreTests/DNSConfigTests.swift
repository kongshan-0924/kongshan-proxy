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

        // 三条，顺序即优先级：自定义代理规则 → 旁路直连 → geosite-cn。
        // 前两条的存在理由见 `testDirectDomainsResolveLocally`。
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(dnsRules.count, 3)
        XCTAssertEqual(dnsRules[0]["domain_suffix"] as? [String], ["custom.example"])
        XCTAssertEqual(dnsRules[0]["server"] as? String, "dns-remote")
        XCTAssertEqual(dnsRules[1]["domain"] as? [String], ["localhost"])
        XCTAssertEqual(dnsRules[1]["server"] as? String, "dns-cn")
        XCTAssertEqual(dnsRules[2]["rule_set"] as? String, "geosite-cn")
        XCTAssertEqual(dnsRules[2]["action"] as? String, "route")
        XCTAssertEqual(dnsRules[2]["server"] as? String, "dns-cn")

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

    /// 用户显式指定引导解析器时，dns-bootstrap 使用独立上游，与国内 DoH 解耦：
    /// 一台上游抖动不再同时打掉「节点域名解析」与「国内域名解析」。
    func testBootstrapResolverCanBeOverriddenIndependently() throws {
        let settings = DNSSettings(
            domesticDoH: "https://119.29.29.29/dns-query",
            remoteDoH: DNSSettings.defaults.remoteDoH,
            bootstrapResolver: "114.114.114.114"
        )
        let root = try json(try ConfigGenerator.generate(input(dnsSettings: settings)))
        let servers = try XCTUnwrap((root["dns"] as? [String: Any])?["servers"] as? [[String: Any]])

        XCTAssertEqual(servers[0]["tag"] as? String, "dns-bootstrap")
        XCTAssertEqual(servers[0]["type"] as? String, "udp")
        XCTAssertEqual(servers[0]["server"] as? String, "114.114.114.114")
        XCTAssertEqual(servers[0]["server_port"] as? Int, 53)
        // 国内 DoH 仍是用户选择的 119.29.29.29——解耦意味着引导不再跟随它。
        XCTAssertEqual(servers[1]["tag"] as? String, "dns-cn")
        XCTAssertEqual(servers[1]["server"] as? String, "119.29.29.29")
    }

    /// 引导解析器只接受 IP（IPv4/IPv6）或留空；域名/URL/带端口一律拒绝——
    /// 引导解析器是 UDP 直连，填域名会在解析它自身时引入新的依赖。
    func testBootstrapResolverValidation() throws {
        for valid in ["", "114.114.114.114", "2400:da00::1"] {
            let settings = DNSSettings(
                domesticDoH: DNSSettings.defaults.domesticDoH,
                remoteDoH: DNSSettings.defaults.remoteDoH,
                bootstrapResolver: valid
            )
            XCTAssertNoThrow(try settings.validated(), "expected valid: \(valid)")
        }
        for invalid in [
            "dns.alidns.com",
            "https://114.114.114.114/dns-query",
            "223.5.5.5:53",
            "not-an-ip"
        ] {
            let settings = DNSSettings(
                domesticDoH: DNSSettings.defaults.domesticDoH,
                remoteDoH: DNSSettings.defaults.remoteDoH,
                bootstrapResolver: invalid
            )
            XCTAssertThrowsError(try settings.validated(), "expected invalid: \(invalid)")
        }
    }

    /// 旧版 settings.json 的 dnsSettings 没有 bootstrapResolver 字段，
    /// 解码必须回退为空（跟随国内 DoH），不能整体解码失败丢掉用户 DNS 设置。
    func testOldDNSSettingsDecodesWithoutBootstrapResolver() throws {
        let data = Data(
            #"{"domesticDoH":"https://223.5.5.5/dns-query","remoteDoH":"https://8.8.8.8/dns-query"}"#.utf8
        )
        let settings = try JSONDecoder().decode(DNSSettings.self, from: data)
        XCTAssertEqual(settings, .defaults)
        XCTAssertEqual(settings.bootstrapResolver, "")
    }

    /// 编码必须带上 bootstrapResolver：应用持久化后重新加载，独立引导配置不能丢。
    func testBootstrapResolverSurvivesEncodeDecodeRoundTrip() throws {
        let original = DNSSettings(
            domesticDoH: "https://119.29.29.29/dns-query",
            remoteDoH: DNSSettings.defaults.remoteDoH,
            bootstrapResolver: "114.114.114.114"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DNSSettings.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.bootstrapResolver, "114.114.114.114")
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
        let customBootstrap = DNSSettings(
            domesticDoH: "https://119.29.29.29/dns-query",
            remoteDoH: "https://dns.google/dns-query",
            bootstrapResolver: "114.114.114.114"
        )
        let core = SingBoxProcess(binaryURL: singBoxURL)

        for (mode, dnsSettings) in [
            (ProxyMode.systemProxy, DNSSettings.defaults),
            (.tun, .defaults),
            (.systemProxy, custom),
            (.tun, custom),
            (.systemProxy, customBootstrap),
            (.tun, customBootstrap)
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

    /// 旁路域名在**路由**上走 direct，若解析仍掉到 `final: dns-remote`，
    /// 就会经代理去问远端解析器再把答案拿回来直连——解析随代理一起抖，
    /// 拿回来的地址还可能本地根本连不通。真机 2026-08-26：旁路的内网域每次卡满 10 秒，
    /// 2 小时 44 分内 26 次失败。
    func testDirectDomainsResolveLocally() throws {
        var settings = routingSettings
        settings.bypassDomains = ["localhost", "*.corp.example", ".lab.example", "nas.example"]
        let root = try json(try ConfigGenerator.generate(input(routingSettings: settings)))
        let rules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])

        let bypass = try XCTUnwrap(rules.first { $0["domain"] as? [String] != nil && $0["server"] as? String == "dns-cn" })
        XCTAssertEqual(bypass["domain"] as? [String], ["localhost", "nas.example"])
        // `*.` 与 `.` 两种写法都要落到 domain_suffix，与路由那条旁路规则用的是同一份拆法。
        XCTAssertEqual(bypass["domain_suffix"] as? [String], ["corp.example", "lab.example"])
        XCTAssertEqual(bypass["action"] as? String, "route")

        // 路由与 DNS 必须覆盖同一批域名，否则又会出现「路由直连、解析走代理」的错配。
        let routeRules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let routeBypass = try XCTUnwrap(routeRules.first {
            $0["outbound"] as? String == "direct" && $0["domain"] as? [String] != nil
        })
        XCTAssertEqual(routeBypass["domain"] as? [String], bypass["domain"] as? [String])
        XCTAssertEqual(routeBypass["domain_suffix"] as? [String], bypass["domain_suffix"] as? [String])
    }

    /// 自定义规则在路由上优先于旁路，DNS 上也必须保持同一优先级。
    /// 否则 fakeip 模式下这些域名会拿到真实 IP 而不是假 IP，丢掉域名信息后按 IP 匹配路由，
    /// 就绕过了用户显式指定的出口。
    func testCustomProxyRulesOutrankBypassInDNS() throws {
        var settings = routingSettings
        settings.bypassDomains = ["*.example"]
        settings.customRules = [
            CustomRouteRule(order: 0, type: .domainSuffix, value: "mail.example", action: .proxy, proxyGroup: "手动选择"),
            CustomRouteRule(order: 1, type: .ipCIDR, value: "1.2.3.0/24", action: .proxy, proxyGroup: "手动选择"),
            CustomRouteRule(order: 2, type: .domain, value: "vpn.example", action: .direct)
        ]
        let root = try json(try ConfigGenerator.generate(
            input(proxyMode: .tun, routingSettings: settings)
        ))
        let rules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])

        let mail = try XCTUnwrap(rules.firstIndex { ($0["domain_suffix"] as? [String]) == ["mail.example"] })
        let bypass = try XCTUnwrap(rules.firstIndex { ($0["domain_suffix"] as? [String]) == ["example"] })
        XCTAssertEqual(rules[mail]["server"] as? String, "dns-remote")
        XCTAssertLessThan(mail, bypass, "自定义代理规则必须排在旁路之前")

        // IP CIDR 在解析阶段还没有 IP，塞进 DNS 规则会让内核校验失败，必须跳过。
        XCTAssertNil(rules.first { $0["ip_cidr"] != nil })
        // 指向 direct 的自定义规则不需要单独截胡：它和旁路的落点本来就一样。
        XCTAssertNil(rules.first { ($0["domain"] as? [String]) == ["vpn.example"] && $0["server"] as? String == "dns-remote" })

        // 与内网规则同理：必须排在 fakeip 之前，否则旁路域名照样掉进假 IP。
        let fakeIP = try XCTUnwrap(rules.firstIndex { $0["server"] as? String == "dns-fakeip" })
        XCTAssertLessThan(bypass, fakeIP)
    }

    /// 直连路径常常没有 IPv6 出口，解析器却照样返回 AAAA，内核挑中它去 dial 就得到
    /// `network is unreachable` / `no route to host`。只调顺序、不禁用 IPv6。
    ///
    /// 必须写在 `dns.strategy` 上：server 级 `domain_strategy` 管的是解析器自己的域名，
    /// 语义不对，且与 `domain_resolver` 同时出现会被 sing-box 1.12 判为 legacy 而 FATAL。
    /// 真机 `sing-box check` 的回归由 `testSystemAndTUNDefaultAndCustomDNSPassBundledCoreCheck` 兜底。
    func testResolutionPrefersIPv4WithoutDisablingIPv6() throws {
        for mode in [ProxyMode.systemProxy, .tun] {
            let dns = try XCTUnwrap(
                json(try ConfigGenerator.generate(input(proxyMode: mode, lanResolver: lanSnapshot)))["dns"] as? [String: Any]
            )
            XCTAssertEqual(dns["strategy"] as? String, "prefer_ipv4", "mode=\(mode)")
            let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
            for server in servers {
                XCTAssertNil(
                    server["domain_strategy"],
                    "server 级 domain_strategy 是 legacy 写法，1.14 会移除：\(server["tag"] ?? "?")"
                )
            }
        }
    }

    private func input(
        proxyMode: ProxyMode = .systemProxy,
        dnsSettings: DNSSettings = .defaults,
        tunSettings: TunSettings = .defaults,
        lanResolver: LANResolverSnapshot = .empty,
        routingSettings: RoutingSettings? = nil
    ) -> ConfigInput {
        ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "memory-only"),
            routing: RoutingConfiguration(
                settings: routingSettings ?? self.routingSettings,
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
                mixedPort: 31_080,
                clashPort: 31_909,
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
