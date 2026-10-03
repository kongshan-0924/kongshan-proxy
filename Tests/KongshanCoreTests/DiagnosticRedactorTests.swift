import Foundation
import XCTest
@testable import KongshanCore

/// 「可公开分享」诊断包。原有导出只去凭据，节点地址、SNI、自定义规则、内网 DNS、告警里的地址
/// 都原样带出；贴到公开场合就全漏了。
final class DiagnosticRedactorTests: XCTestCase {
    private let node = ProxyNode(
        name: "家宽 (someone)", protocolType: .vless, server: "198.51.100.23", port: 443,
        uuid: "11111111-2222-3333-4444-555555555555", tlsEnabled: true, sni: "front.example.com",
        transport: TransportOptions(kind: .websocket, path: "/ws?token=abc", headers: ["Host": "cdn.example.com"])
    )

    private func shareable(modes: Set<ProxyMode> = [.tun, .systemProxy]) throws -> (String, [String: Any]) {
        var settings = RoutingSettings(
            customRules: [CustomRouteRule(order: 0, type: .domainSuffix, value: "private-intranet.example",
                                          action: .proxy, proxyGroup: "手动选择")],
            bypassDomains: ["oa.corp.example"],
            bypassCIDRs: ["10.20.0.0/16"],
            blockAds: false
        )
        settings.tunExcludeCIDRs = ["10.30.0.0/16"]
        let input = ConfigInput(
            nodes: [node], selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "runtime-secret"),
            routing: RoutingConfiguration(settings: settings, ruleSets: PreparedRuleSets(
                geositeCN: URL(fileURLWithPath: "/tmp/geosite-cn.srs"),
                geoipCN: URL(fileURLWithPath: "/tmp/geoip-cn.srs"), ads: nil)),
            enabledModes: modes,
            lanResolver: LANResolverSnapshot(servers: ["10.0.0.53"], searchDomains: ["corp.example"])
        )
        let data = try DiagnosticRedactor.shareableConfig(from: ConfigGenerator.generate(input))
        let text = String(decoding: data, as: UTF8.self)
        return (text, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    func testShareableConfigHidesEverythingThatPointsAtAPersonOrNetwork() throws {
        let (text, _) = try shareable()
        for secret in ["198.51.100.23", "front.example.com", "cdn.example.com", "token=abc",
                       "private-intranet.example", "oa.corp.example", "10.20.0.0", "10.30.0.0",
                       "10.0.0.53", "corp.example", "runtime-secret", "11111111-2222"] {
            XCTAssertFalse(text.contains(secret), "不该出现：\(secret)")
        }
    }

    /// 结构、规则顺序与出站去向要留下——排查看的是「哪条规则把流量送去了哪」。
    func testShareableConfigKeepsStructureAndRouting() throws {
        let (_, root) = try shareable()
        let route = try XCTUnwrap(root["route"] as? [String: Any])
        let rules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let custom = try XCTUnwrap(rules.first { ($0["domain_suffix"] as? [String]) == ["已隐藏 1 项"] })
        XCTAssertEqual(custom["outbound"] as? String, "手动选择")
        XCTAssertTrue(rules.contains { ($0["rule_set"] as? [String]) == ["geosite-cn", "geoip-cn"] })
        XCTAssertTrue(rules.contains { ($0["ip_cidr"] as? [String]) == ["240.0.0.0/4"] }, "内置的假 IP 段人人相同，留着")

        let outbound = try XCTUnwrap((root["outbounds"] as? [[String: Any]])?.first { $0["type"] as? String == "vless" })
        XCTAssertEqual(outbound["server"] as? String, "server-1.example")
        XCTAssertEqual(outbound["server_port"] as? Int, 443)
        XCTAssertEqual(outbound["uuid"] as? String, "<redacted>")

        let dnsRules = try XCTUnwrap((root["dns"] as? [String: Any])?["rules"] as? [[String: Any]])
        let reserved = try XCTUnwrap(dnsRules.first { $0["action"] as? String == "predefined" })
        XCTAssertEqual(reserved["domain_suffix"] as? [String], ConfigGenerator.nonexistentSuffixes)
    }

    func testTextRedactionHidesAddressesLinksAndNamesButNotTimesOrVersions() {
        let text = """
        12:31:55 家宽 (someone) 在10 分钟内 77/138 次建连失败；dial tcp 198.51.100.23:443 与 [2001:db8:c010:1402:3::6]:443、
        fe80::1%en0；规则集 https://rules.example.com/x.yaml?token=1 下载失败；内核 1.13.21，平均 1.06%；配置 全部
        """
        let redacted = DiagnosticRedactor.redactText(text, replacing: [("家宽 (someone)", "节点#1"), ("全部", "配置#1")])
        XCTAssertTrue(redacted.contains("12:31:55"), "时间不是地址")
        XCTAssertTrue(redacted.contains("1.13.21"))
        XCTAssertTrue(redacted.contains("节点#1 在10 分钟内"))
        XCTAssertTrue(redacted.contains("配置 全部"), "太短的名字不换：会误伤正文里的同形字")
        for leaked in ["198.51.100.23", "2001:db8", "fe80::1", "rules.example.com", "someone"] {
            XCTAssertFalse(redacted.contains(leaked), "不该出现：\(leaked)\n\(redacted)")
        }
    }
}
