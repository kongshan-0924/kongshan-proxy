import Foundation
import XCTest
@testable import KongshanCore

/// 订阅给 TLS 节点写的 `client-fingerprint`（uTLS）与 `alpn` 要用上。
/// 真机 2026-10-07：机场 125 个 anytls 节点都写了 `client-fingerprint: chrome`、`alpn: [h2]`，
/// 空山只对 VLESS 读指纹，anytls / trojan 一律以 Go 默认的握手特征去连。
final class SubscriptionTLSOptionsTests: XCTestCase {
    private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!

    private func nodes(_ proxies: String) throws -> [ProxyNode] {
        try ClashSubscriptionConverter.convert(yaml: "proxies:\n" + proxies, sourceID: sourceID).nodes
    }

    private func tls(of node: ProxyNode) throws -> [String: Any] {
        let data = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 31_080, clashPort: 31_909, secret: "s")
        ))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let outbound = try XCTUnwrap(outbounds.first { $0["tag"] as? String == ConfigGenerator.outboundTag(for: node) })
        return try XCTUnwrap(outbound["tls"] as? [String: Any])
    }

    func testAnyTLSUsesSubscriptionFingerprintAndALPN() throws {
        let node = try XCTUnwrap(try nodes("""
          - {name: a, type: anytls, server: a.example.com, port: 443, password: p, alpn: [h2], client-fingerprint: chrome, sni: a.example.com, skip-cert-verify: true}
        """).first)
        XCTAssertEqual(node.utlsFingerprint, "chrome")
        XCTAssertEqual(node.alpn, ["h2"])

        let tls = try tls(of: node)
        XCTAssertEqual((tls["utls"] as? [String: Any])?["fingerprint"] as? String, "chrome")
        XCTAssertEqual((tls["utls"] as? [String: Any])?["enabled"] as? Bool, true)
        XCTAssertEqual(tls["alpn"] as? [String], ["h2"])
    }

    func testTrojanReadsFingerprintButSkipsALPNOverWebSocket() throws {
        let parsed = try nodes("""
          - {name: plain, type: trojan, server: t.example.com, port: 443, password: p, alpn: "h2,http/1.1", client-fingerprint: Firefox}
          - {name: ws, type: trojan, server: t.example.com, port: 443, password: p, alpn: [h2], client-fingerprint: chrome, network: ws, ws-opts: {path: /x}}
        """)
        XCTAssertEqual(parsed[0].utlsFingerprint, "firefox", "大小写不敏感")
        XCTAssertEqual(parsed[0].alpn, ["h2", "http/1.1"], "逗号分隔的字符串也认")
        XCTAssertEqual(parsed[1].utlsFingerprint, "chrome")
        XCTAssertNil(parsed[1].alpn, "ws 走 HTTP/1.1 升级，协商成 h2 反而连不上")
        XCTAssertNil(try tls(of: parsed[1])["alpn"])
    }

    /// 内核认不出的指纹会让整份配置校验失败——宁可当没写。
    func testUnknownFingerprintIsDropped() throws {
        let node = try XCTUnwrap(try nodes("""
          - {name: a, type: anytls, server: a.example.com, port: 443, password: p, client-fingerprint: netscape}
        """).first)
        XCTAssertNil(node.utlsFingerprint)
        XCTAssertNil(try tls(of: node)["utls"])
        XCTAssertNil(node.alpn)
    }

    /// Clash 的 `fingerprint` 是证书指纹，不是 uTLS；旧写法把它当 uTLS 兜底，会把一串十六进制交给内核。
    func testVLESSCertificateFingerprintIsNotTreatedAsUTLS() throws {
        let parsed = try nodes("""
          - {name: cert, type: vless, server: v.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, fingerprint: 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08}
          - {name: utls, type: vless, server: v.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, tls: true, client-fingerprint: safari}
        """)
        XCTAssertNil(parsed[0].utlsFingerprint)
        XCTAssertEqual(parsed[1].utlsFingerprint, "safari")
    }

    /// 旧版本存下的节点没有 alpn 字段，照常解码。
    func testNodeWithoutALPNStillDecodes() throws {
        let legacy = #"{"id":"00000000-0000-0000-0000-000000000009","name":"n","protocolType":"anytls","server":"a.example.com","port":443,"password":"p","tlsEnabled":true,"skipCertificateVerification":false}"#
        let node = try JSONDecoder().decode(ProxyNode.self, from: Data(legacy.utf8))
        XCTAssertNil(node.alpn)
    }
}
