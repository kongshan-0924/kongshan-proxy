import Foundation
import XCTest
@testable import KongshanCore

final class TunConfigTests: XCTestCase {
    func testProxyModeAndTunDefaultsRoundTripThroughJSON() throws {
        let values = [ProxyMode.systemProxy, .tun]
        XCTAssertEqual(try JSONDecoder().decode([ProxyMode].self, from: JSONEncoder().encode(values)), values)
        XCTAssertEqual(TunSettings.defaults, TunSettings(
            strictRoute: false,
            interfaceName: "kongshan-tun",
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
        // 默认 mixed：system 栈在部分 macOS 版本有已知问题（sing-box#2500/#3529）
        XCTAssertEqual(tun["stack"] as? String, TunSettings.defaults.stack.rawValue)
        XCTAssertEqual(TunSettings.defaults.stack, .mixed)
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
                interfaceName: "kongshan-tun",
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
        RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "runtime-secret")
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
    func testLegacyTunSettingsJSONWithoutStackDecodesToMixed() throws {
        let legacy = """
        {"strictRoute":true,"interfaceName":"kongshan-tun","addresses":["172.19.0.1/30"],"mtu":9000}
        """
        let settings = try JSONDecoder().decode(TunSettings.self, from: Data(legacy.utf8))
        XCTAssertEqual(settings.stack, .mixed)
        XCTAssertTrue(settings.strictRoute)

        var custom = TunSettings.defaults
        custom.stack = .gvisor
        let decoded = try JSONDecoder().decode(TunSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(decoded.stack, .gvisor)
    }

    func testStripIPv6RemovesIPv6AddressesKeepsIPv4() {
        let stripped = TunSettings.defaults.stripIPv6()
        XCTAssertEqual(stripped.addresses, ["172.19.0.1/30"])
        // 其它字段不变
        XCTAssertEqual(stripped.mtu, TunSettings.defaults.mtu)
        XCTAssertEqual(stripped.stack, TunSettings.defaults.stack)
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

    func testStripIPv6OnIPv6OnlySettingsYieldsEmptyAddresses() {
        // 极端情况：只有 IPv6 地址（用户自定义）。剥掉后变空数组——
        // 这种配置本就无法工作，但行为要可预测：不静默保留 IPv6。
        var v6Only = TunSettings.defaults
        v6Only.addresses = ["fd00::1/64"]
        let stripped = v6Only.stripIPv6()
        XCTAssertEqual(stripped.addresses, [])
    }
}
