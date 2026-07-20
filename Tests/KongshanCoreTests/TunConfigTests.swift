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
        XCTAssertEqual(tun["interface_name"] as? String, "kongshan-tun")
        XCTAssertEqual(tun["address"] as? [String], ["172.19.0.1/30", "fdfe:dcba:9876::1/126"])
        XCTAssertEqual(tun["mtu"] as? Int, 9_000)
        XCTAssertEqual(tun["auto_route"] as? Bool, true)
        XCTAssertEqual(tun["strict_route"] as? Bool, true)
        XCTAssertEqual(tun["stack"] as? String, "system")
        XCTAssertEqual(tun["route_exclude_address"] as? [String], settings.bypassCIDRs)
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
            bypassCIDRs: [" 10.0.0.0/8 "],
            blockAds: false
        )

        let root = try json(try ConfigGenerator.generate(input(
            strictRoute: false,
            routingSettings: settings
        )))
        let tun = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)

        XCTAssertEqual(tun["route_exclude_address"] as? [String], ["10.0.0.0/8"])
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
