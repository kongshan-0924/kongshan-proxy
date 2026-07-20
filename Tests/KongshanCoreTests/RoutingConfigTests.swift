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

        XCTAssertEqual(routeRules.count, 9)
        assertRule(routeRules[0], field: "domain_suffix", value: "example.com", outbound: "direct")
        assertRule(routeRules[1], field: "domain_keyword", value: "video", outbound: "自动选择")
        assertRule(routeRules[2], field: "domain", value: "blocked.example", outbound: "reject")
        assertRule(routeRules[3], field: "ip_cidr", value: "203.0.113.0/24", outbound: "direct")
        assertRule(routeRules[4], field: "process_name", value: "backup", outbound: "手动选择")
        XCTAssertFalse(routeRules.contains { ($0["domain"] as? [String])?.contains("disabled.example") == true })

        XCTAssertEqual(routeRules[5]["domain"] as? [String], ["localhost"])
        XCTAssertEqual(routeRules[5]["domain_suffix"] as? [String], ["local", "internal"])
        XCTAssertEqual(routeRules[5]["ip_cidr"] as? [String], ["192.168.0.0/16"])
        XCTAssertEqual(routeRules[5]["outbound"] as? String, "direct")
        XCTAssertEqual(routeRules[6]["ip_is_private"] as? Bool, true)
        XCTAssertEqual(routeRules[6]["outbound"] as? String, "direct")
        XCTAssertEqual(routeRules[7]["rule_set"] as? String, "geosite-category-ads-all")
        XCTAssertEqual(routeRules[7]["outbound"] as? String, "reject")
        XCTAssertEqual(routeRules[8]["rule_set"] as? [String], ["geosite-cn", "geoip-cn"])
        XCTAssertEqual(routeRules[8]["outbound"] as? String, "direct")
        XCTAssertTrue(routeRules.allSatisfy { $0["action"] as? String == "route" })
        XCTAssertEqual(route["final"] as? String, "自动选择")

        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(ruleSets.map { $0["tag"] as? String }, ["geosite-cn", "geoip-cn", "geosite-category-ads-all"])
        XCTAssertTrue(ruleSets.allSatisfy { $0["type"] as? String == "local" && $0["format"] as? String == "binary" })
        XCTAssertEqual(ruleSets[0]["path"] as? String, "/tmp/geosite-cn.srs")
        XCTAssertEqual(ruleSets[1]["path"] as? String, "/tmp/geoip-cn.srs")
        XCTAssertEqual(ruleSets[2]["path"] as? String, "/tmp/geosite-category-ads-all.srs")

        XCTAssertEqual(settings.bypassDomains, ["localhost", "*.local", ".internal"])
        XCTAssertEqual(settings.systemProxyBypassEntries, ["localhost", "*.local", ".internal", "192.168.0.0/16"])
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

        XCTAssertEqual(routeRules.count, 2)
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
