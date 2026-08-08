import Foundation
import HelperProtocol
import XCTest
@testable import KongshanCore

final class TunConfigTests: XCTestCase {
    func testProxyModeAndTunDefaultsRoundTripThroughJSON() throws {
        let values = [ProxyMode.systemProxy, .tun]
        XCTAssertEqual(try JSONDecoder().decode([ProxyMode].self, from: JSONEncoder().encode(values)), values)
        XCTAssertEqual(TunSettings.defaults, TunSettings(
            strictRoute: false,
            addresses: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            mtu: 9_000
        ))
    }

    func testTunInboundContainsRouteExclusionsAndLoopPrevention() throws {
        let settings = RoutingSettings(
            customRules: [],
            bypassDomains: ["localhost", "*.local", "*.cn"],
            bypassCIDRs: ["10.0.0.0/8", "192.168.0.0/16", "fc00::/7"],
            tunExcludeCIDRs: ["172.16.0.0/12", "fe80::/10"],
            blockAds: false
        )
        let root = try json(try ConfigGenerator.generate(input(
            strictRoute: true,
            routingSettings: settings
        )))
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])

        XCTAssertEqual(inbounds.count, 1)
        let tun = inbounds[0]
        XCTAssertEqual(tun["type"] as? String, "tun")
        XCTAssertEqual(tun["tag"] as? String, "tun-in")
        // macOS 下不指定 interface_name，交给 sing-box 自动分配 utunN
        XCTAssertNil(tun["interface_name"])
        XCTAssertEqual(tun["address"] as? [String], ["172.19.0.1/30", "fdfe:dcba:9876::1/126"])
        XCTAssertEqual(tun["mtu"] as? Int, 9_000)
        XCTAssertEqual(tun["auto_route"] as? Bool, true)
        XCTAssertEqual(tun["strict_route"] as? Bool, true)
        // 强制 gvisor：system/mixed 栈的 TCP 转发在部分网络（多默认网关/企业网）会失效。
        XCTAssertEqual(tun["stack"] as? String, "gvisor")
        // 跳过 TUN 与跳过代理是两份独立列表，不得互相串用
        XCTAssertEqual(tun["route_exclude_address"] as? [String], settings.tunExcludeCIDRs)
        XCTAssertFalse((tun["route_exclude_address"] as? [String] ?? []).contains("10.0.0.0/8"))
        XCTAssertFalse((tun["route_exclude_address"] as? [String] ?? []).contains("*.local"))

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
    }

    func testSystemProxyInputKeepsMixedInboundAndNoTunRouteFields() throws {
        let root = try json(try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: runtime
        )))
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        let route = try XCTUnwrap(root["route"] as? [String: Any])

        XCTAssertEqual(inbound["type"] as? String, "mixed")
        XCTAssertEqual(inbound["listen_port"] as? Int, Int(runtime.mixedPort))
        XCTAssertNil(inbound["route_exclude_address"])
        XCTAssertNil(route["auto_detect_interface"])
    }

    func testTunRouteExclusionsUseValidatedCIDRs() throws {
        let settings = RoutingSettings(
            customRules: [],
            bypassDomains: [],
            bypassCIDRs: [],
            tunExcludeCIDRs: [" 10.0.0.0/8 "],
            blockAds: false
        )

        let root = try json(try ConfigGenerator.generate(input(
            strictRoute: false,
            routingSettings: settings
        )))
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)

        XCTAssertEqual(tun["route_exclude_address"] as? [String], ["10.0.0.0/8"])
    }

    func testForcedProxyCIDRRemovesConflictingTunRouteExclusion() throws {
        let settings = RoutingSettings(
            customRules: [
                CustomRouteRule(
                    order: 0,
                    type: .ipCIDR,
                    value: "10.20.30.40",
                    action: .proxy,
                    proxyGroup: "手动选择"
                )
            ],
            bypassDomains: [],
            bypassCIDRs: [],
            tunExcludeCIDRs: ["127.0.0.0/8", "10.0.0.0/8", "192.168.0.0/16", "::1/128"],
            blockAds: false
        )

        let root = try json(try ConfigGenerator.generate(input(
            strictRoute: false,
            routingSettings: settings
        )))
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        let exclusions = try XCTUnwrap(tun["route_exclude_address"] as? [String])

        XCTAssertEqual(exclusions, ["127.0.0.0/8", "192.168.0.0/16", "::1/128"])
    }

    func testDirectModeKeepsTunRouteExclusionsDespiteSavedForcedRule() throws {
        var settings = RoutingSettings.defaults
        settings.customRules = [
            CustomRouteRule(
                order: 0,
                type: .ipCIDR,
                value: "10.20.30.40/32",
                action: .proxy,
                proxyGroup: "手动选择"
            )
        ]

        let root = try json(try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: runtime,
            routing: RoutingConfiguration(
                settings: settings,
                ruleSets: PreparedRuleSets(
                    geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                    geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
                    ads: nil
                )
            ),
            enabledModes: [.tun],
            outboundMode: .direct
        )))
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)

        XCTAssertEqual(tun["route_exclude_address"] as? [String], settings.tunExcludeCIDRs)
    }

    func testBothModesEnabledProducesMixedAndTunInbounds() throws {
        let root = try json(try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: runtime,
            routing: nil,
            enabledModes: [.systemProxy, .tun]
        )))
        let inbounds = try XCTUnwrap(root["inbounds"] as? [[String: Any]])

        XCTAssertEqual(inbounds.count, 2)
        XCTAssertEqual(inbounds.compactMap { $0["type"] as? String }.sorted(), ["mixed", "tun"])
        let mixed = try XCTUnwrap(inbounds.first { $0["type"] as? String == "mixed" })
        XCTAssertEqual(mixed["listen_port"] as? Int, Int(runtime.mixedPort))
        let tun = try XCTUnwrap(inbounds.first { $0["type"] as? String == "tun" })
        XCTAssertEqual(tun["auto_route"] as? Bool, true)

        // 同时开启时仍需 TUN 的 DNS 劫持与出接口探测
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["auto_detect_interface"] as? Bool, true)
    }

    func testBothModesConfigPassesBundledCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: runtime,
            routing: RoutingConfiguration(settings: .defaults, ruleSets: ruleSets),
            enabledModes: [.systemProxy, .tun]
        ))
        let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testGeneratedTUNConfigPassesHelperTrustBoundary() throws {
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(
                mixedPort: 31_080,
                clashPort: 31_909,
                secret: "0123456789abcdef"
            ),
            routing: nil,
            enabledModes: [.tun]
        ))

        let validation = HelperConfigWhitelist.validate(config)
        XCTAssertTrue(validation.ok, validation.reason ?? "helper rejected generated TUN config")
        let sanitized = try XCTUnwrap(validation.sanitizedData)
        let root = try json(sanitized)
        let cache = try XCTUnwrap(
            (root["experimental"] as? [String: Any])?["cache_file"] as? [String: Any]
        )
        XCTAssertEqual(
            cache["path"] as? String,
            HelperConstants.stateDirectory + "/fakeip-cache-v2.db"
        )
    }

    /// 白名单回归必须覆盖真机会出现的每种组合，不能只测 TUN-only：
    /// TUN+系统代理是最常见的（多一个 mixed 入站，走白名单的 loopback/服务端口分支），
    /// TUN+直连不生成 cache_file（走 cache_file 缺省分支）。生成器一改监听地址、端口范围
    /// 或 experimental 形状，这里立刻红——否则测试全绿而真机报 "config rejected"。
    func testEveryGeneratedTUNModeCombinationPassesHelperTrustBoundary() throws {
        // 白名单要求 clash_api secret ≥ 16 字符（真机是 32 字节随机 base64）。
        let secureRuntime = RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: "0123456789abcdef")
        let combinations: [(name: String, modes: Set<ProxyMode>, outbound: OutboundMode, expectsCache: Bool)] = [
            ("TUN", [.tun], .rule, true),
            ("TUN+系统代理", [.systemProxy, .tun], .rule, true),
            ("TUN+全局", [.tun], .global, true),
            ("TUN+直连", [.tun], .direct, false)
        ]

        for combination in combinations {
            let config = try ConfigGenerator.generate(ConfigInput(
                nodes: [node],
                selectedNodeID: node.id,
                runtime: secureRuntime,
                enabledModes: combination.modes,
                outboundMode: combination.outbound
            ))
            let validation = HelperConfigWhitelist.validate(config)
            XCTAssertTrue(validation.ok, "\(combination.name)：\(validation.reason ?? "被 helper 拒绝")")
            let root = try json(try XCTUnwrap(validation.sanitizedData))
            let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
            if combination.expectsCache {
                let cache = try XCTUnwrap(
                    experimental["cache_file"] as? [String: Any],
                    "\(combination.name) 应带 fakeip 缓存"
                )
                XCTAssertEqual(
                    cache["path"] as? String,
                    HelperConstants.stateDirectory + "/fakeip-cache-v2.db",
                    "\(combination.name) 的缓存路径必须被改写到 root 自有目录"
                )
            } else {
                XCTAssertNil(experimental["cache_file"], "\(combination.name) 不该带 fakeip 缓存")
            }
        }
    }

    /// 生成器分配的端口必须落在 helper 白名单放行的区间里（两者同源于 HelperConstants）。
    func testRuntimeHighPortsStayInsideHelperWhitelistRange() throws {
        let port = try RuntimeSecrets.availableHighPort()
        XCTAssertTrue(
            HelperConstants.loopbackHighPorts.contains(Int(port)),
            "分配到 \(port)，不在 helper 放行的 \(HelperConstants.loopbackHighPorts)"
        )
    }

    func testTunRuleModeDNSUsesFakeIPButSystemProxyDoesNot() throws {
        // TUN + 规则模式：DNS 应含 fakeip 服务器 + independent_cache（修 DNS-over-TUN 在多网关网络失效）
        let tunRoot = try json(try ConfigGenerator.generate(input(strictRoute: true, routingSettings: .defaults)))
        let tunDNS = try XCTUnwrap(tunRoot["dns"] as? [String: Any])
        let tunServers = try XCTUnwrap(tunDNS["servers"] as? [[String: Any]])
        XCTAssertTrue(tunServers.contains { $0["type"] as? String == "fakeip" }, "TUN 规则模式应有 fakeip 服务器")
        XCTAssertEqual(tunServers.first { $0["type"] as? String == "fakeip" }?["inet4_range"] as? String, "240.0.0.0/4")
        XCTAssertEqual(tunDNS["independent_cache"] as? Bool, true)
        let tunExperimental = try XCTUnwrap(tunRoot["experimental"] as? [String: Any])
        let fakeIPCache = try XCTUnwrap(tunExperimental["cache_file"] as? [String: Any])
        XCTAssertEqual(fakeIPCache["enabled"] as? Bool, true)
        XCTAssertEqual(fakeIPCache["store_fakeip"] as? Bool, true)
        XCTAssertEqual(
            fakeIPCache["path"] as? String,
            AppIdentity.supportDirectory.appending(path: "fakeip-cache-v2.db").path
        )

        let diagnostic = try json(try ConfigGenerator.diagnosticSnapshot(from: try ConfigGenerator.generate(
            input(strictRoute: true, routingSettings: .defaults)
        )))
        let diagnosticCache = try XCTUnwrap(
            (diagnostic["experimental"] as? [String: Any])?["cache_file"] as? [String: Any]
        )
        XCTAssertNil(diagnosticCache["path"], "诊断快照不应泄露本机用户目录")
        XCTAssertEqual(diagnosticCache["store_fakeip"] as? Bool, true)

        // 系统代理模式：走 socket、DNS 不经 TUN，保持 real-ip，不应有 fakeip
        let sysRoot = try json(try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: runtime,
            routing: nil,
            enabledModes: [.systemProxy]
        )))
        let sysDNS = try XCTUnwrap(sysRoot["dns"] as? [String: Any])
        let sysServers = try XCTUnwrap(sysDNS["servers"] as? [[String: Any]])
        XCTAssertFalse(sysServers.contains { $0["type"] as? String == "fakeip" }, "系统代理模式不应有 fakeip")
        XCTAssertNil((sysRoot["experimental"] as? [String: Any])?["cache_file"])
    }

    /// 物理网关与订阅规则也可能占用 198.18/15；改用独立的保留 240/4，
    /// 并确保本内核 Fake-IP 在订阅规则之前固定走代理。
    func testTunPinsFakeIPBeforeConflictingSubscriptionCIDRAndPassesCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)

        let hy2 = ProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
            name: "Dmit-H2",
            protocolType: .hysteria2,
            server: "69.63.217.24",
            port: 45724,
            password: "test-password",
            sni: "69.63.217.24",
            skipCertificateVerification: true
        )
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [hy2],
            selectedNodeID: hy2.id,
            runtime: RuntimeParameters(mixedPort: 31080, clashPort: 31909, secret: "verify-secret"),
            routing: RoutingConfiguration(
                settings: .defaults,
                ruleSets: ruleSets,
                subscriptionRules: [
                    SubscriptionRule(type: .ipCIDR, value: "240.0.0.0/5", target: "DIRECT")
                ]
            ),
            enabledModes: [.tun],
            outboundMode: .rule,
            tunSettings: .defaults,
            dnsSettings: .defaults
        ))

        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let rules = try XCTUnwrap((root["route"] as? [String: Any])?["rules"] as? [[String: Any]])
        let fakeIPIndex = try XCTUnwrap(rules.firstIndex {
            ($0["ip_cidr"] as? [String])?.contains("240.0.0.0/4") == true
        })
        let conflictingSubscriptionIndex = try XCTUnwrap(rules.firstIndex {
            ($0["ip_cidr"] as? [String])?.contains("240.0.0.0/5") == true
        })
        XCTAssertLessThan(fakeIPIndex, conflictingSubscriptionIndex)
        XCTAssertEqual(rules[fakeIPIndex]["outbound"] as? String, "手动选择")
        XCTAssertFalse(rules.contains {
            $0["network"] as? String == "udp" && $0["port_range"] as? String == "443:443"
        }, "QUIC 全局拒绝没有解决根因且会产生 operation not permitted，不应保留")

        let result = try await SingBoxProcess(binaryURL: singBoxURL).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testStrictOffAndOnTunConfigsPassBundledCoreCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleSets = try await compileRuleSets(in: directory)
        let core = SingBoxProcess(binaryURL: singBoxURL)

        for strictRoute in [false, true] {
            let config = try ConfigGenerator.generate(input(
                strictRoute: strictRoute,
                routingSettings: .defaults,
                ruleSets: ruleSets
            ))
            let result = try await core.check(config: config)
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }
    }

    private func input(
        strictRoute: Bool,
        routingSettings: RoutingSettings,
        ruleSets: PreparedRuleSets? = nil
    ) -> ConfigInput {
        let prepared = ruleSets ?? PreparedRuleSets(
            geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
            geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"),
            ads: nil
        )
        return ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: runtime,
            routing: RoutingConfiguration(settings: routingSettings, ruleSets: prepared),
            proxyMode: .tun,
            tunSettings: TunSettings(
                strictRoute: strictRoute,
                addresses: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
                mtu: 9_000
            )
        )
    }

    private var node: ProxyNode {
        ProxyNode(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
            name: "test",
            protocolType: .shadowsocks,
            server: "1.1.1.1",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
    }

    private var runtime: RuntimeParameters {
        RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: "runtime-secret")
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

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

extension TunConfigTests {
    func testLegacyTunSettingsIgnoresRemovedFields() throws {
        let legacy = """
        {"strictRoute":true,"interfaceName":"kongshan-tun","addresses":["172.19.0.1/30"],"mtu":9000,"stack":"mixed"}
        """
        let settings = try JSONDecoder().decode(TunSettings.self, from: Data(legacy.utf8))
        XCTAssertTrue(settings.strictRoute)
        XCTAssertEqual(settings.addresses, ["172.19.0.1/30"])
    }

    func testStripIPv6RemovesIPv6AddressesKeepsIPv4() {
        let stripped = TunSettings.defaults.stripIPv6()
        XCTAssertEqual(stripped.addresses, ["172.19.0.1/30"])
        // 其它字段不变
        XCTAssertEqual(stripped.mtu, TunSettings.defaults.mtu)
        XCTAssertEqual(stripped.strictRoute, TunSettings.defaults.strictRoute)
        // dnsServerAddress 只看 IPv4，剥掉 IPv6 不影响
        XCTAssertEqual(stripped.dnsServerAddress, TunSettings.defaults.dnsServerAddress)
    }

    func testStripIPv6NoOpWhenAlreadyIPv4Only() {
        var v4Only = TunSettings.defaults
        v4Only.addresses = ["10.0.0.1/24"]
        // 已经没有 IPv6 时返回自身（不是新实例）
        XCTAssertTrue(v4Only.stripIPv6() == v4Only)
    }

    func testStripIPv6OnIPv6OnlySettingsFallsBackToDefaultIPv4() {
        var v6Only = TunSettings.defaults
        v6Only.addresses = ["fd00::1/64"]
        let stripped = v6Only.stripIPv6()
        XCTAssertEqual(stripped.addresses, ["172.19.0.1/30"])
    }
}
