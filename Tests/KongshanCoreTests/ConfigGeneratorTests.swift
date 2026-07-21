import XCTest
@testable import KongshanCore

final class ConfigGeneratorTests: XCTestCase {
    func testGeneratesMixedInboundControllerAndPolicyGroups() throws {
        let data = try ConfigGenerator.generate(input)
        let root = try json(data)

        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["type"] as? String, "mixed")
        XCTAssertEqual(inbound["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbound["listen_port"] as? Int, 51_080)

        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let clashAPI = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        XCTAssertEqual(clashAPI["external_controller"] as? String, "127.0.0.1:51909")
        XCTAssertEqual(clashAPI["secret"] as? String, "runtime-secret")

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        XCTAssertEqual(outbound(tag: "手动选择", in: outbounds)?["type"] as? String, "selector")
        XCTAssertEqual(outbound(tag: "自动选择", in: outbounds)?["interval"] as? String, "5m")
        XCTAssertEqual(outbound(tag: "自建", in: outbounds)?["outbounds"] as? [String], [ConfigGenerator.outboundTag(for: nodes[3])])

        let route = try XCTUnwrap(root["route"] as? [String: Any])
        XCTAssertEqual(route["final"] as? String, "手动选择")
    }

    func testMapsProtocolSpecificOutboundFields() throws {
        let outbounds = try XCTUnwrap(try json(ConfigGenerator.generate(input))["outbounds"] as? [[String: Any]])

        let ss = try XCTUnwrap(outbound(for: nodes[0], in: outbounds))
        XCTAssertEqual(ss["type"] as? String, "shadowsocks")
        XCTAssertEqual(ss["method"] as? String, "2022-blake3-aes-128-gcm")

        let trojan = try XCTUnwrap(outbound(for: nodes[1], in: outbounds))
        XCTAssertEqual((trojan["tls"] as? [String: Any])?["server_name"] as? String, "tr.example.com")
        XCTAssertEqual((trojan["transport"] as? [String: Any])?["type"] as? String, "ws")

        let vmess = try XCTUnwrap(outbound(for: nodes[2], in: outbounds))
        XCTAssertEqual(vmess["uuid"] as? String, "00000000-0000-0000-0000-000000000003")
        XCTAssertEqual(vmess["alter_id"] as? Int, 0)

        let hysteria2 = try XCTUnwrap(outbound(for: nodes[3], in: outbounds))
        XCTAssertEqual(hysteria2["up_mbps"] as? Int, 20)
        XCTAssertEqual((hysteria2["obfs"] as? [String: Any])?["password"] as? String, "mask")

        let anyTLS = try XCTUnwrap(outbound(for: nodes[4], in: outbounds))
        XCTAssertEqual(anyTLS["type"] as? String, "anytls")
        XCTAssertEqual((anyTLS["tls"] as? [String: Any])?["server_name"] as? String, "any.example.com")
    }

    func testDiagnosticSnapshotRemovesClashRuntimeValues() throws {
        let snapshot = try ConfigGenerator.diagnosticSnapshot(from: ConfigGenerator.generate(input))
        let text = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
        let root = try json(snapshot)

        XCTAssertFalse(text.contains("runtime-secret"))
        XCTAssertFalse(text.contains("51909"))
        XCTAssertNil((root["experimental"] as? [String: Any])?["clash_api"])
        XCTAssertEqual(((root["inbounds"] as? [[String: Any]])?.first)?["listen_port"] as? Int, 51_080)
    }

    func testRejectsEmptyNodeList() {
        let empty = ConfigInput(nodes: [], selectedNodeID: nil, runtime: runtime)

        XCTAssertThrowsError(try ConfigGenerator.generate(empty)) { error in
            XCTAssertEqual(error as? ConfigGenerationError, .noNodes)
        }
    }

    func testRuntimeSecretsAreRandomAndPortsAreHigh() throws {
        let first = try RuntimeSecrets.secret()
        let second = try RuntimeSecrets.secret()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Data(base64Encoded: first)?.count, 32)
        for _ in 0..<4 {
            XCTAssertTrue((49_152...65_535).contains(Int(try RuntimeSecrets.availableHighPort())))
        }
    }

    private var input: ConfigInput {
        ConfigInput(nodes: nodes, selectedNodeID: nodes[0].id, runtime: runtime)
    }

    private var runtime: RuntimeParameters {
        RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "runtime-secret")
    }

    private var nodes: [ProxyNode] {
        [
            ProxyNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                sourceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "ss", protocolType: .shadowsocks, server: "1.1.1.1", port: 443,
                password: "c2VjcmV0", method: "2022-blake3-aes-128-gcm"
            ),
            ProxyNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                sourceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "tr", protocolType: .trojan, server: "tr.example.com", port: 443,
                password: "p", tlsEnabled: true, sni: "tr.example.com",
                transport: TransportOptions(kind: .websocket, path: "/ws", headers: ["Host": "edge.example.com"])
            ),
            ProxyNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                sourceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "vm", protocolType: .vmess, server: "vm.example.com", port: 443,
                uuid: "00000000-0000-0000-0000-000000000003", security: "auto", alterID: 0
            ),
            ProxyNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                name: "hy", protocolType: .hysteria2, server: "hy.example.com", port: 443,
                password: "p", tlsEnabled: true, sni: "hy.example.com", obfsPassword: "mask",
                uploadMbps: 20, downloadMbps: 100
            ),
            ProxyNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                sourceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "any", protocolType: .anytls, server: "any.example.com", port: 443,
                password: "p", tlsEnabled: true, sni: "any.example.com"
            )
        ]
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func outbound(tag: String, in outbounds: [[String: Any]]) -> [String: Any]? {
        outbounds.first { $0["tag"] as? String == tag }
    }

    private func outbound(for node: ProxyNode, in outbounds: [[String: Any]]) -> [String: Any]? {
        outbound(tag: ConfigGenerator.outboundTag(for: node), in: outbounds)
    }
}
