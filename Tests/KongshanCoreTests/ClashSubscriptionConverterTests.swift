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
