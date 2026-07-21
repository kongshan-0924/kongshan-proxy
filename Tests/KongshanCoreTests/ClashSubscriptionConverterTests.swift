import XCTest
@testable import KongshanCore

final class ClashSubscriptionConverterTests: XCTestCase {
    private let sourceID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!

    func testConvertsFiveSupportedProtocols() throws {
        let result = try ClashSubscriptionConverter.convert(yaml: Self.allProtocolsYAML, sourceID: sourceID)

        XCTAssertEqual(result.nodes.map(\.protocolType), [.shadowsocks, .trojan, .vmess, .hysteria2, .anytls])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertTrue(result.nodes.allSatisfy { $0.sourceID == sourceID })

        let shadowsocks = result.nodes[0]
        XCTAssertEqual(shadowsocks.method, "2022-blake3-aes-128-gcm")
        XCTAssertEqual(shadowsocks.password, "c2VjcmV0")

        let trojan = result.nodes[1]
        XCTAssertEqual(trojan.sni, "tr.example.com")
        XCTAssertTrue(trojan.skipCertificateVerification)
        XCTAssertEqual(trojan.transport?.kind, .websocket)
        XCTAssertEqual(trojan.transport?.path, "/ws")
        XCTAssertEqual(trojan.transport?.headers["Host"], "edge.example.com")

        let vmess = result.nodes[2]
        XCTAssertEqual(vmess.uuid, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(vmess.security, "auto")
        XCTAssertEqual(vmess.alterID, 0)

        let hysteria2 = result.nodes[3]
        XCTAssertEqual(hysteria2.obfsPassword, "mask")
        XCTAssertEqual(hysteria2.uploadMbps, 20)
        XCTAssertEqual(hysteria2.downloadMbps, 100)

        let anyTLS = result.nodes[4]
        XCTAssertEqual(anyTLS.password, "p")
        XCTAssertEqual(anyTLS.sni, "any.example.com")
    }

    /// 机场绝大多数 SS 节点带 `plugin: obfs`（simple-obfs）。必须解析并在生成时输出
    /// sing-box 的 obfs-local + plugin_opts，否则节点能握手/测速却传不了数据（打不开网站）。
    func testShadowsocksObfsPluginParsedAndEmitted() throws {
        let yaml = """
        proxies:
          - { name: 'HK obfs', type: ss, server: a.example.com, port: 12022, cipher: aes-128-gcm, password: pw, plugin: obfs, plugin-opts: { mode: http, host: mask.microsoft.com }, udp: true }
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        let node = try XCTUnwrap(result.nodes.first)
        XCTAssertEqual(node.pluginName, "obfs-local")
        XCTAssertEqual(node.pluginOptions, "obfs=http;obfs-host=mask.microsoft.com")

        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: result.nodes,
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 19_100, clashPort: 19_101, secret: "s"),
            outboundMode: .global
        ))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let ss = try XCTUnwrap(outbounds.first { $0["type"] as? String == "shadowsocks" })
        XCTAssertEqual(ss["plugin"] as? String, "obfs-local")
        XCTAssertEqual(ss["plugin_opts"] as? String, "obfs=http;obfs-host=mask.microsoft.com")
    }

    /// 不认识的 SS 插件应跳过该节点并计入 warnings，而不是生成一个连得上却传不了数据的坏节点。
    func testUnsupportedShadowsocksPluginIsSkipped() throws {
        let yaml = """
        proxies:
          - { name: bad, type: ss, server: b.example.com, port: 443, cipher: aes-128-gcm, password: pw, plugin: v2ray-plugin }
          - { name: good, type: ss, server: c.example.com, port: 443, cipher: aes-128-gcm, password: pw }
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        XCTAssertEqual(result.nodes.map(\.name), ["good"])
        XCTAssertTrue(result.warnings.contains { $0.contains("bad") })
    }

    func testSkipsUnsupportedAndMalformedNodes() throws {
        let yaml = Self.allProtocolsYAML + """

          - {name: skip, type: tuic, server: skip.example.com, port: 443}
          - {name: broken, type: ss, server: broken.example.com, port: 443, cipher: aes-128-gcm}
        """

        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)

        XCTAssertEqual(result.nodes.count, 5)
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.warnings.contains { $0.contains("skip") && $0.contains("tuic") })
        XCTAssertTrue(result.warnings.contains { $0.contains("broken") && $0.contains("password") })
    }

    func testRejectsDocumentWithoutUsableNodes() {
        let yaml = "proxies: [{name: skip, type: tuic, server: example.com, port: 443}]"

        XCTAssertThrowsError(try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)) { error in
            XCTAssertEqual(error as? SubscriptionConversionError, .noSupportedNodes)
        }
    }

    private static let allProtocolsYAML = """
    proxies:
      - {name: ss, type: ss, server: 1.1.1.1, port: 443, cipher: 2022-blake3-aes-128-gcm, password: c2VjcmV0}
      - name: tr
        type: trojan
        server: tr.example.com
        port: 443
        password: p
        sni: tr.example.com
        skip-cert-verify: true
        network: ws
        ws-opts:
          path: /ws
          headers: {Host: edge.example.com}
      - {name: vm, type: vmess, server: vm.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, cipher: auto, alterId: 0}
      - {name: hy, type: hysteria2, server: hy.example.com, port: 443, password: p, obfs: salamander, obfs-password: mask, up: 20, down: 100}
      - {name: any, type: anytls, server: any.example.com, port: 443, password: p, sni: any.example.com}
    """
}

extension ClashSubscriptionConverterTests {
    func testSubscriptionInfoNodesAreRecognisedAndRealNodesAreNot() {
        func node(_ name: String) -> ProxyNode {
            ProxyNode(name: name, protocolType: .shadowsocks, server: "a.com", port: 443)
        }

        for name in [
            "491.89 G | 500.00 G",
            "Traffic Reset：10 Days Left",
            "Expire Date：2027/08/07",
            "剩余流量：120GB",
            "官网：example.com",
            "套餐到期：2027-08-07"
        ] {
            XCTAssertTrue(node(name).isSubscriptionInfo, name)
        }

        for name in [
            "🇭🇰 Hong Kong 01",
            "日本 IEPL 03",
            "US-Los Angeles CN2 GIA",
            "自建 Hysteria2"
        ] {
            XCTAssertFalse(node(name).isSubscriptionInfo, name)
        }
    }
}

extension ClashSubscriptionConverterTests {
    func testProxyGroupsAreImportedAndBadOnesSkipped() throws {
        let yaml = """
        proxies:
          - {name: A, type: ss, server: a.com, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: Netflix, type: select, proxies: [A]}
          - {name: AutoFast, type: url-test, proxies: [A]}
          - {name: 自动选择, type: select, proxies: [A]}
          - {name: "bad{name}", type: select, proxies: [A]}
          - {name: Netflix, type: select, proxies: [A]}
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: UUID())

        XCTAssertEqual(result.policyGroups.map(\.name), ["Netflix", "AutoFast"])
        XCTAssertEqual(result.policyGroups.first { $0.name == "AutoFast" }?.kind, .urltest)
        XCTAssertEqual(result.policyGroups.first { $0.name == "Netflix" }?.kind, .selector)
    }
}

extension ClashSubscriptionConverterTests {
    /// 节点 ID 必须跨刷新稳定：选中节点、组选择、延迟表都以它为键。
    func testNodeIDsAreStableAcrossRefreshesAndDistinctForDuplicateNames() throws {
        let sourceID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let yaml = """
        proxies:
          - {name: HK-1, type: ss, server: a.com, port: 443, cipher: aes-128-gcm, password: p}
          - {name: HK-1, type: ss, server: b.com, port: 443, cipher: aes-128-gcm, password: p}
          - {name: JP-1, type: ss, server: c.com, port: 443, cipher: aes-128-gcm, password: p}
        """

        let first = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        let second = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)

        XCTAssertEqual(first.nodes.map(\.id), second.nodes.map(\.id))
        XCTAssertEqual(Set(first.nodes.map(\.id)).count, 3, "同名节点也要有不同的稳定 ID")

        // 服务器地址变化（机场换 IP）不改变身份；换订阅源则必须不同。
        let movedYAML = yaml.replacingOccurrences(of: "a.com", with: "a2.com")
        let moved = try ClashSubscriptionConverter.convert(yaml: movedYAML, sourceID: sourceID)
        XCTAssertEqual(first.nodes[0].id, moved.nodes[0].id)

        let otherSource = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: UUID())
        XCTAssertNotEqual(first.nodes[0].id, otherSource.nodes[0].id)
    }
}
