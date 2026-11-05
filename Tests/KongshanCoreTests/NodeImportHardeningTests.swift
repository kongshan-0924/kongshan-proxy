import Foundation
import XCTest
@testable import KongshanCore

/// 2026-10-25 审计：一个坏节点会让整份配置被内核拒绝（所有节点一起不可用），或者节点静默导入成连不上的样子。
/// 这里钉住各条入口的处理：能纠正的纠正，纠正不了的在导入时就报出来。凭据全是占位值。
final class NodeImportHardeningTests: XCTestCase {
    private let sourceID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

    private func base64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 分享链接

    /// SIP002 示例里的 `simple-obfs` 内核不认（plugin not found），要换成 `obfs-local`；其余插件导入时就拒。
    func testShadowsocksLinkPluginNamesAreNormalised() throws {
        let userInfo = base64("aes-256-gcm:pw-placeholder")
        let node = try NodeShareLink.parse(
            "ss://\(userInfo)@example.com:443/?plugin=simple-obfs%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example.com#n"
        )
        XCTAssertEqual(node.pluginName, "obfs-local")
        XCTAssertEqual(node.pluginOptions, "obfs=http;obfs-host=cdn.example.com")
        XCTAssertThrowsError(try NodeShareLink.parse("ss://\(userInfo)@example.com:443/?plugin=shadow-tls%3Bhost%3Dx#n"))
    }

    /// 内核认不得的指纹（大小写、自造名字）当没写；Reality 短 ID 写坏了导入时就拒。
    func testVLESSLinkFingerprintAndShortIDAreValidated() throws {
        let base = "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=reality&pbk=public-key-placeholder"
        XCTAssertEqual(try NodeShareLink.parse(base + "&fp=Chrome&sid=0123abcd#n").utlsFingerprint, "chrome")
        XCTAssertNil(try NodeShareLink.parse(base + "&fp=hello&sid=0123abcd#n").utlsFingerprint)
        XCTAssertEqual(try NodeShareLink.parse(base + "&sid=0123abcd#n").realityShortID, "0123abcd")
        XCTAssertNil(try NodeShareLink.parse(base + "#n").realityShortID)
        for bad in ["abc", "xyz1", "0123456789abcdef01"] {
            XCTAssertThrowsError(try NodeShareLink.parse(base + "&sid=\(bad)#n"), bad)
        }
    }

    /// 没接的传输方式不能静默当成裸 TCP 导入：握手后不通，用户还看不出原因。
    func testUnsupportedTransportsAreRejected() throws {
        let vless = "vless://00000000-0000-0000-0000-000000000001@example.com:443?security=tls"
        XCTAssertNoThrow(try NodeShareLink.parse(vless + "&type=ws&path=%2Fws#n"))
        XCTAssertNoThrow(try NodeShareLink.parse(vless + "&type=tcp#n"))
        for bad in ["&type=httpupgrade", "&type=h2", "&type=tcp&headerType=http"] {
            XCTAssertThrowsError(try NodeShareLink.parse(vless + bad + "#n"), bad)
        }
        let vmess = #"{"v":"2","ps":"n","add":"example.com","port":"443","id":"00000000-0000-0000-0000-000000000001","net":"kcp"}"#
        XCTAssertThrowsError(try NodeShareLink.parse("vmess://" + base64(vmess)))
    }

    /// 开了 obfs 却没给密码：空密码内核直接拒（missing obfs password）。
    func testHysteria2LinkWithEmptyObfsPasswordIsRejected() {
        XCTAssertThrowsError(try NodeShareLink.parse("hysteria2://pw@example.com:443?obfs=salamander&obfs-password=#n"))
        XCTAssertThrowsError(try NodeShareLink.parse("hysteria2://pw@example.com:443?obfs=salamander#n"))
        XCTAssertNoThrow(try NodeShareLink.parse("hysteria2://pw@example.com:443?obfs=salamander&obfs-password=mask#n"))
    }

    // MARK: - Clash 订阅

    /// 不加引号的纯数字被 YAML 解析成整数：密码不能因此被判缺失，Reality 短 ID 不能被静默丢掉。
    func testClashNumericScalarsAreReadAsStrings() throws {
        let yaml = """
        proxies:
          - {name: 1234, type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: 123456}
          - name: reality
            type: vless
            server: vl.example.com
            port: 443
            uuid: 00000000-0000-0000-0000-000000000001
            tls: true
            reality-opts: {public-key: public-key-placeholder, short-id: 12345678}
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        XCTAssertEqual(result.nodes.map(\.name), ["1234", "reality"])
        XCTAssertEqual(result.nodes[0].password, "123456")
        XCTAssertEqual(result.nodes[1].realityShortID, "12345678")
    }

    /// Clash 写了 `obfs: salamander` 却没给密码：跳过并告警，而不是静默不带 obfs 去连。
    func testClashHysteria2ObfsWithoutPasswordIsSkipped() throws {
        let yaml = """
        proxies:
          - {name: hy-bad, type: hysteria2, server: hy.example.com, port: 443, password: pw, obfs: salamander}
          - {name: hy-ok, type: hysteria2, server: hy.example.com, port: 443, password: pw}
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        XCTAssertEqual(result.nodes.map(\.name), ["hy-ok"])
        XCTAssertFalse(result.warnings.isEmpty)
    }

    // MARK: - 枚举字段白名单

    /// 加密方式、flow、vmess security 写了内核不认的值：一个节点就让整份配置被拒（真内核 FATAL）。
    /// 别名换成内核写法，换不了的跳过并告警。
    func testClashEnumFieldsAreNormalisedOrSkipped() throws {
        let yaml = """
        proxies:
          - {name: ss-alias, type: ss, server: a.example.com, port: 443, cipher: chacha20-poly1305, password: pw}
          - {name: ss-bad, type: ss, server: a.example.com, port: 443, cipher: salsa20, password: pw}
          - {name: vless-udp443, type: vless, server: a.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, flow: xtls-rprx-vision-udp443}
          - {name: vless-bad, type: vless, server: a.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, flow: xtls-rprx-direct}
          - {name: vmess-bad, type: vmess, server: a.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, alterId: 0, cipher: aes-128-ctr}
          - {name: vmess-ok, type: vmess, server: a.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, alterId: 0, cipher: AUTO}
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        XCTAssertEqual(result.nodes.map(\.name), ["ss-alias", "vless-udp443", "vmess-ok"])
        XCTAssertEqual(result.nodes[0].method, "chacha20-ietf-poly1305")
        XCTAssertEqual(result.nodes[1].flow, "xtls-rprx-vision")
        XCTAssertEqual(result.nodes[2].security, "auto")
        XCTAssertEqual(result.warnings.filter { $0.contains("内核不支持") }.count, 3, "\(result.warnings)")
    }

    func testShareLinkEnumFieldsAreValidated() throws {
        XCTAssertEqual(try NodeShareLink.parse("ss://\(base64("chacha20-poly1305:pw"))@a.example.com:443#n").method, "chacha20-ietf-poly1305")
        XCTAssertThrowsError(try NodeShareLink.parse("ss://\(base64("salsa20:pw"))@a.example.com:443#n"))
        let vless = "vless://00000000-0000-0000-0000-000000000001@a.example.com:443?security=tls"
        XCTAssertNil(try NodeShareLink.parse(vless + "#n").flow)
        XCTAssertEqual(try NodeShareLink.parse(vless + "&flow=xtls-rprx-vision#n").flow, "xtls-rprx-vision")
        XCTAssertThrowsError(try NodeShareLink.parse(vless + "&flow=bogus#n"))
        let vmess = #"{"v":"2","ps":"n","add":"a.example.com","port":"443","id":"00000000-0000-0000-0000-000000000001","scy":"aes-128-ctr"}"#
        XCTAssertThrowsError(try NodeShareLink.parse("vmess://" + base64(vmess)))
    }

    /// relay 是链式代理，不能当成「挑一个」的 selector：跳过并告警，引用它的组里显示为「未导入」。
    func testClashRelayGroupsAreSkipped() throws {
        let yaml = """
        proxies:
          - {name: a, type: ss, server: a.example.com, port: 443, cipher: aes-128-gcm, password: pw}
          - {name: b, type: ss, server: b.example.com, port: 443, cipher: aes-128-gcm, password: pw}
        proxy-groups:
          - {name: chain, type: relay, proxies: [a, b]}
          - {name: pick, type: select, proxies: [chain, a]}
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        XCTAssertEqual(result.policyGroups.map(\.name), ["pick"])
        XCTAssertTrue(result.warnings.contains { $0.contains("relay") && $0.contains("chain") }, "\(result.warnings)")
    }

    // MARK: - XHTTP

    /// XHTTP 由内置内核（官方 + 移植的 XHTTP）支持：订阅与链接都要带上路径、Host、上下行方式与 ALPN（XHTTP 按它选 HTTP 版本）。
    /// 单独下行地址与 HTTP/3 没接，导入时就拒，不让一个节点拖垮整份配置。
    func testClashXHTTPNodesAreImported() throws {
        let yaml = """
        proxies:
          - {name: xh, type: vless, server: cdn.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, servername: cdn.example.com, alpn: [h2], client-fingerprint: chrome, network: xhttp, xhttp-opts: {host: cdn.example.com, mode: packet-up, path: /api/v2/abc}}
          - {name: xh-h3, type: vless, server: cdn.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, alpn: [h3], network: xhttp, xhttp-opts: {path: /x}}
          - {name: xh-split, type: vless, server: cdn.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, network: xhttp, xhttp-opts: {path: /x, download-settings: {server: dl.example.com}}}
          - {name: xh-mode, type: vless, server: cdn.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, network: xhttp, xhttp-opts: {path: /x, mode: bogus}}
        """
        let result = try ClashSubscriptionConverter.convert(yaml: yaml, sourceID: sourceID)
        XCTAssertEqual(result.nodes.map(\.name), ["xh"])
        XCTAssertEqual(result.warnings.filter { $0.contains("不支持的传输方式 xhttp") }.count, 3, "\(result.warnings)")
        let node = result.nodes[0]
        XCTAssertEqual(node.transport, TransportOptions(kind: .xhttp, path: "/api/v2/abc", host: "cdn.example.com", mode: "packet-up"))
        XCTAssertEqual(node.alpn, ["h2"])
    }

    func testXHTTPShareLink() throws {
        let base = "vless://00000000-0000-0000-0000-000000000001@cdn.example.com:443?security=tls&sni=cdn.example.com&type=xhttp"
        let node = try NodeShareLink.parse(base + "&path=%2Fx&host=cdn.example.com&mode=stream-one&alpn=h2#n")
        XCTAssertEqual(node.transport, TransportOptions(kind: .xhttp, path: "/x", host: "cdn.example.com", mode: "stream-one"))
        XCTAssertEqual(node.alpn, ["h2"])
        XCTAssertEqual(try NodeShareLink.parse(base + "#n").transport?.mode, "auto")
        XCTAssertThrowsError(try NodeShareLink.parse(base + "&alpn=h3#n"))
        XCTAssertThrowsError(try NodeShareLink.parse(base + "&mode=bogus#n"))
        let split = #"{"downloadSettings":{"address":"dl.example.com"}}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        XCTAssertThrowsError(try NodeShareLink.parse(base + "&extra=\(split)#n"))
    }

    /// 生成的 XHTTP 出站要能被内置内核接受（官方内核会报 unknown transport type: xhttp）。
    func testXHTTPOutboundPassesBundledKernelCheck() async throws {
        let node = ProxyNode(
            name: "xh", protocolType: .vless, server: "cdn.example.com", port: 443,
            uuid: "00000000-0000-0000-0000-000000000001", tlsEnabled: true, sni: "cdn.example.com",
            transport: TransportOptions(kind: .xhttp, path: "/x", host: "cdn.example.com", mode: "packet-up", xPaddingBytes: "100-1000"),
            utlsFingerprint: "chrome", alpn: ["h2"]
        )
        let data = try ConfigGenerator.generate(ConfigInput(
            nodes: [node], selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "s")
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbound = try XCTUnwrap((root["outbounds"] as? [[String: Any]])?.first { $0["type"] as? String == "vless" })
        let transport = try XCTUnwrap(outbound["transport"] as? [String: Any])
        XCTAssertEqual(transport["type"] as? String, "xhttp")
        XCTAssertEqual(transport["mode"] as? String, "packet-up")
        XCTAssertEqual(transport["x_padding_bytes"] as? String, "100-1000")
        XCTAssertEqual((outbound["tls"] as? [String: Any])?["alpn"] as? [String], ["h2"])

        let kernel = TestPaths.vendoredKernel
        let check = try await SingBoxProcess(binaryURL: kernel).check(config: data)
        XCTAssertEqual(check.exitCode, 0, check.stderr)
    }

    // MARK: - 配置生成

    /// Reality 必须带 uTLS：订阅或链接没写指纹时补 chrome，否则一个节点让整份配置校验失败。
    func testRealityWithoutFingerprintGetsDefaultUTLS() throws {
        let node = ProxyNode(
            name: "reality", protocolType: .vless, server: "vl.example.com", port: 443,
            uuid: "00000000-0000-0000-0000-000000000001", tlsEnabled: true,
            realityPublicKey: "public-key-placeholder", realityShortID: "0123abcd"
        )
        let data = try ConfigGenerator.generate(ConfigInput(
            nodes: [node], selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "s")
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbound = try XCTUnwrap((root["outbounds"] as? [[String: Any]])?.first { $0["type"] as? String == "vless" })
        let tls = try XCTUnwrap(outbound["tls"] as? [String: Any])
        let utls = try XCTUnwrap(tls["utls"] as? [String: Any])
        XCTAssertEqual(utls["fingerprint"] as? String, "chrome")
    }
}
