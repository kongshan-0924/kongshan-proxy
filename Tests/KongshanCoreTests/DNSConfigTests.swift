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

        XCTAssertEqual(servers.count, 2)
        assertDoH(
            servers[0],
            tag: "dns-cn",
            server: "223.5.5.5",
            path: "/dns-query",
            detour: nil
        )
        assertDoH(
            servers[1],
            tag: "dns-remote",
            server: "8.8.8.8",
            path: "/dns-query",
            detour: "自动选择"
        )
        XCTAssertNil(dns["fakeip"])
        XCTAssertEqual(dns["final"] as? String, "dns-remote")

        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(dnsRules.count, 1)
        XCTAssertEqual(dnsRules[0]["rule_set"] as? String, "geosite-cn")
        XCTAssertEqual(dnsRules[0]["action"] as? String, "route")
        XCTAssertEqual(dnsRules[0]["server"] as? String, "dns-cn")

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-cn")
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
        XCTAssertEqual(systemRules[0]["domain_suffix"] as? [String], ["custom.example"])
        XCTAssertFalse(systemRules.contains { $0["action"] as? String == "hijack-dns" })

        let tunRoot = try json(try ConfigGenerator.generate(input(proxyMode: .tun)))
        let tunRoute = try XCTUnwrap(tunRoot["route"] as? [String: Any])
        let tunRules = try XCTUnwrap(tunRoute["rules"] as? [[String: Any]])
        XCTAssertEqual(tunRules[0]["action"] as? String, "sniff")
        XCTAssertEqual(tunRules[1]["protocol"] as? String, "dns")
        XCTAssertEqual(tunRules[1]["action"] as? String, "hijack-dns")
        XCTAssertEqual(tunRules[2]["domain_suffix"] as? [String], ["custom.example"])
        XCTAssertEqual(tunRules[3]["domain"] as? [String], ["localhost"])
        XCTAssertEqual(tunRules[4]["ip_is_private"] as? Bool, true)
        XCTAssertEqual(tunRules[5]["rule_set"] as? [String], ["geosite-cn", "geoip-cn"])
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

    private func input(
        proxyMode: ProxyMode = .systemProxy,
        dnsSettings: DNSSettings = .defaults
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
            proxyMode: proxyMode,
            dnsSettings: dnsSettings
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
