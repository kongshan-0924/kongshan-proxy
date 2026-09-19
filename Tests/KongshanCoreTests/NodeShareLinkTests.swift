import Foundation
import XCTest
@testable import KongshanCore

/// 分享链接解析。所有用例的凭据都是占位值，不含任何真实节点信息。
final class NodeShareLinkTests: XCTestCase {
    private func base64URLSafeNoPadding(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Shadowsocks

    func testParsesModernShadowsocksLink() throws {
        let userInfo = base64URLSafeNoPadding("aes-256-gcm:pw-placeholder")
        let node = try NodeShareLink.parse("ss://\(userInfo)@example.com:8388#%E9%A6%99%E6%B8%AF%20A")

        XCTAssertEqual(node.protocolType, .shadowsocks)
        XCTAssertEqual(node.server, "example.com")
        XCTAssertEqual(node.port, 8_388)
        XCTAssertEqual(node.method, "aes-256-gcm")
        XCTAssertEqual(node.password, "pw-placeholder")
        XCTAssertEqual(node.name, "香港 A", "备注是百分号编码的，要解码")
    }

    /// 旧格式把 `method:password@host:port` 整段编码。仍在流通，必须认。
    func testParsesLegacyFullyEncodedShadowsocksLink() throws {
        let whole = base64URLSafeNoPadding("aes-128-gcm:pw-placeholder@example.org:1234")
        let node = try NodeShareLink.parse("ss://\(whole)")

        XCTAssertEqual(node.server, "example.org")
        XCTAssertEqual(node.port, 1_234)
        XCTAssertEqual(node.method, "aes-128-gcm")
        XCTAssertEqual(node.password, "pw-placeholder")
    }

    func testParsesShadowsocksPlugin() throws {
        let userInfo = base64URLSafeNoPadding("aes-256-gcm:pw-placeholder")
        let node = try NodeShareLink.parse(
            "ss://\(userInfo)@example.com:443?plugin=obfs-local%3Bobfs%3Dtls%3Bobfs-host%3Dwww.example.com"
        )
        XCTAssertEqual(node.pluginName, "obfs-local")
        XCTAssertEqual(node.pluginOptions, "obfs=tls;obfs-host=www.example.com")
    }

    // MARK: - Trojan / AnyTLS

    func testParsesTrojanWithWebSocket() throws {
        let node = try NodeShareLink.parse(
            "trojan://pw-placeholder@example.com:443?sni=edge.example.com&type=ws&path=/tunnel&host=cdn.example.com#TR"
        )
        XCTAssertEqual(node.protocolType, .trojan)
        XCTAssertEqual(node.password, "pw-placeholder")
        XCTAssertTrue(node.tlsEnabled, "Trojan 的安全性全靠伪装成 HTTPS，TLS 恒开")
        XCTAssertEqual(node.sni, "edge.example.com")
        XCTAssertEqual(node.transport?.kind, .websocket)
        XCTAssertEqual(node.transport?.path, "/tunnel")
        XCTAssertEqual(node.transport?.headers["Host"], "cdn.example.com")
        XCTAssertEqual(node.name, "TR")
    }

    func testParsesAnyTLSAndInsecureFlag() throws {
        let node = try NodeShareLink.parse("anytls://pw-placeholder@example.com:8443?insecure=1&sni=a.example.com")
        XCTAssertEqual(node.protocolType, .anytls)
        XCTAssertTrue(node.skipCertificateVerification)
        XCTAssertEqual(node.sni, "a.example.com")
    }

    // MARK: - VMess

    func testParsesVMessJSONLink() throws {
        let json = """
        {"v":"2","ps":"VM 节点","add":"example.com","port":"443","id":"00000000-0000-0000-0000-000000000001",\
        "aid":"0","scy":"auto","net":"ws","host":"cdn.example.com","path":"/ws","tls":"tls","sni":"edge.example.com"}
        """
        let node = try NodeShareLink.parse("vmess://\(base64URLSafeNoPadding(json))")

        XCTAssertEqual(node.protocolType, .vmess)
        XCTAssertEqual(node.name, "VM 节点")
        XCTAssertEqual(node.server, "example.com")
        XCTAssertEqual(node.port, 443)
        XCTAssertEqual(node.uuid, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(node.alterID, 0)
        XCTAssertTrue(node.tlsEnabled)
        XCTAssertEqual(node.sni, "edge.example.com")
        XCTAssertEqual(node.transport?.kind, .websocket)
        XCTAssertEqual(node.transport?.headers["Host"], "cdn.example.com")
    }

    /// 端口/aid 有时是数字、有时是字符串，两种都得吃下。
    func testParsesVMessWithNumericFields() throws {
        let json = """
        {"ps":"n","add":"example.com","port":8443,"id":"00000000-0000-0000-0000-000000000002","aid":0,"net":"grpc","path":"svc"}
        """
        let node = try NodeShareLink.parse("vmess://\(base64URLSafeNoPadding(json))")
        XCTAssertEqual(node.port, 8_443)
        XCTAssertEqual(node.transport?.kind, .grpc)
        XCTAssertEqual(node.transport?.serviceName, "svc")
        XCTAssertFalse(node.tlsEnabled, "没写 tls 就不该开")
    }

    // MARK: - VLESS

    func testParsesVLESSRealityVision() throws {
        let node = try NodeShareLink.parse(
            "vless://00000000-0000-0000-0000-000000000003@example.com:443"
            + "?encryption=none&security=reality&sni=www.example.org&fp=chrome"
            + "&pbk=public-key-placeholder&sid=0123abcd&flow=xtls-rprx-vision&type=tcp#VL"
        )
        XCTAssertEqual(node.protocolType, .vless)
        XCTAssertEqual(node.uuid, "00000000-0000-0000-0000-000000000003")
        XCTAssertTrue(node.tlsEnabled)
        XCTAssertEqual(node.sni, "www.example.org")
        XCTAssertEqual(node.utlsFingerprint, "chrome")
        XCTAssertEqual(node.realityPublicKey, "public-key-placeholder")
        XCTAssertEqual(node.realityShortID, "0123abcd")
        XCTAssertEqual(node.flow, "xtls-rprx-vision")
        XCTAssertNil(node.transport, "type=tcp 不该造出 transport")
    }

    /// 非 reality 时不能把 pbk/sid 带上——那会让生成的配置带上无效的 reality 段。
    func testDropsRealityFieldsWhenSecurityIsNotReality() throws {
        let node = try NodeShareLink.parse(
            "vless://00000000-0000-0000-0000-000000000004@example.com:443?security=tls&pbk=x&sid=y"
        )
        XCTAssertNil(node.realityPublicKey)
        XCTAssertNil(node.realityShortID)
        XCTAssertTrue(node.tlsEnabled)
    }

    // MARK: - Hysteria2

    func testParsesHysteria2WithObfsAndAlias() throws {
        for scheme in ["hysteria2", "hy2"] {
            let node = try NodeShareLink.parse(
                "\(scheme)://pw-placeholder@example.com:8443"
                + "?sni=a.example.com&obfs=salamander&obfs-password=obfs-placeholder&upmbps=50&downmbps=200#HY"
            )
            XCTAssertEqual(node.protocolType, .hysteria2, "hy2 是 hysteria2 的通用别名")
            XCTAssertEqual(node.obfsPassword, "obfs-placeholder")
            XCTAssertEqual(node.uploadMbps, 50)
            XCTAssertEqual(node.downloadMbps, 200)
            XCTAssertTrue(node.tlsEnabled)
        }
    }

    func testIgnoresObfsPasswordWhenObfsDisabled() throws {
        let node = try NodeShareLink.parse("hysteria2://pw-placeholder@example.com:443?obfs-password=x")
        XCTAssertNil(node.obfsPassword, "没开 obfs 就不该带混淆密码")
    }

    // MARK: - 边界

    func testHandlesIPv6Literal() throws {
        let node = try NodeShareLink.parse("trojan://pw-placeholder@[2001:db8::1]:443")
        XCTAssertEqual(node.server, "2001:db8::1")
        XCTAssertEqual(node.port, 443)
    }

    /// 密码里含 `@` 时必须按最后一个 `@` 切，否则服务器地址会被截错。
    func testSplitsOnLastAtSignSoPasswordsMayContainAt() throws {
        let node = try NodeShareLink.parse("trojan://pa%40ss@example.com:443")
        XCTAssertEqual(node.server, "example.com")
        XCTAssertEqual(node.password, "pa@ss")
    }

    func testRejectsGarbage() {
        for bad in ["", "   ", "not a link", "ftp://example.com"] {
            XCTAssertThrowsError(try NodeShareLink.parse(bad), "应拒绝：\(bad)")
        }
    }

    func testRejectsInvalidPort() {
        XCTAssertThrowsError(try NodeShareLink.parse("trojan://pw@example.com:0"))
        XCTAssertThrowsError(try NodeShareLink.parse("trojan://pw@example.com:99999"))
        XCTAssertThrowsError(try NodeShareLink.parse("trojan://pw@example.com"))
    }

    /// 批量粘贴：坏行安静跳过，不能因为一行坏数据整批失败。
    func testParseAllSkipsBadLines() {
        let userInfo = base64URLSafeNoPadding("aes-256-gcm:pw-placeholder")
        let clipboard = """
        ss://\(userInfo)@a.example.com:8388#A

        这是一行说明文字
        trojan://pw-placeholder@b.example.com:443#B
        ftp://nope
        """
        let nodes = NodeShareLink.parseAll(clipboard)
        XCTAssertEqual(nodes.map(\.name), ["A", "B"])
    }

    /// 没有 `#备注` 时用服务器地址兜底，别给出空名字。
    func testFallsBackToHostWhenNoFragment() throws {
        let node = try NodeShareLink.parse("trojan://pw-placeholder@example.com:443")
        XCTAssertEqual(node.name, "example.com")
    }
}
