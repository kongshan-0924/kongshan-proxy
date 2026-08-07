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

    func testDiagnosticModeCanTemporarilyRaiseCoreLogLevel() throws {
        let diagnosticInput = ConfigInput(
            nodes: nodes,
            selectedNodeID: nodes[0].id,
            runtime: runtime,
            coreLogLevel: "debug"
        )
        let root = try json(ConfigGenerator.generate(diagnosticInput))
        XCTAssertEqual((root["log"] as? [String: Any])?["level"] as? String, "debug")
        XCTAssertEqual((try json(ConfigGenerator.generate(input))["log"] as? [String: Any])?["level"] as? String, "info")
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

        let vless = try XCTUnwrap(outbound(for: nodes[5], in: outbounds))
        XCTAssertEqual(vless["uuid"] as? String, "00000000-0000-0000-0000-000000000006")
        XCTAssertEqual(vless["flow"] as? String, "xtls-rprx-vision")
        let tls = try XCTUnwrap(vless["tls"] as? [String: Any])
        XCTAssertEqual((tls["utls"] as? [String: Any])?["fingerprint"] as? String, "chrome")
        XCTAssertEqual((tls["reality"] as? [String: Any])?["public_key"] as? String, "public-key-placeholder")
    }

    func testDiagnosticSnapshotRemovesClashRuntimeValues() throws {
        let snapshot = try ConfigGenerator.diagnosticSnapshot(from: ConfigGenerator.generate(input))
        let text = try XCTUnwrap(String(data: snapshot, encoding: .utf8))
        let root = try json(snapshot)

        XCTAssertFalse(text.contains("runtime-secret"))
        XCTAssertFalse(text.contains("51909"))
        XCTAssertNil((root["experimental"] as? [String: Any])?["clash_api"])
        XCTAssertEqual(((root["inbounds"] as? [[String: Any]])?.first)?["listen_port"] as? Int, 51_080)

        // 节点凭据同样必须脱敏：用户把 config.json 贴群/发 issue 时不能泄漏。
        // nodes 里各协议的密码 / uuid / obfs-password 必须替换为 <redacted>。
        // 注意：outbound 的 tag 字段（"node-<uuid>"）本身含 UUID 字符串，是节点标识不是凭据，
        // 不应被脱敏；所以这里只检查凭据字段本身，不检查整个文本是否含 UUID 子串。
        XCTAssertFalse(text.contains("c2VjcmV0"))
        XCTAssertFalse(text.contains("\"mask\""))
        XCTAssertTrue(text.contains("<redacted>"))

        let outbounds = try XCTUnwrap(root["outbounds"] as? [[String: Any]])
        let ss = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "node-00000000-0000-0000-0000-000000000001" })
        XCTAssertEqual(ss["password"] as? String, "<redacted>")
        let vmess = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "node-00000000-0000-0000-0000-000000000003" })
        XCTAssertEqual(vmess["uuid"] as? String, "<redacted>")
        let hy = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "node-00000000-0000-0000-0000-000000000004" })
        let obfs = try XCTUnwrap(hy["obfs"] as? [String: Any])
        XCTAssertEqual(obfs["password"] as? String, "<redacted>")

        // 嵌套凭据必须一并脱敏：VLESS 的 Reality 参数藏在 tls.reality 下，
        // 0.1.32 加 VLESS 时旧的浅层脱敏漏掉了它（真机 config.json 里明文可见）。
        let vless = try XCTUnwrap(outbounds.first { $0["tag"] as? String == "node-00000000-0000-0000-0000-000000000006" })
        let reality = try XCTUnwrap((vless["tls"] as? [String: Any])?["reality"] as? [String: Any])
        XCTAssertEqual(reality["public_key"] as? String, "<redacted>")
        XCTAssertEqual(vless["uuid"] as? String, "<redacted>")
        XCTAssertFalse(text.contains("public-key-placeholder"))
        // 非凭据字段不能被误伤（否则诊断包失去价值）。
        XCTAssertEqual((vless["tls"] as? [String: Any])?["server_name"] as? String, "edge.example.com")
        XCTAssertEqual(vless["flow"] as? String, "xtls-rprx-vision")
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

    func testVLESSConfigPassesBundledCoreCheck() async throws {
        let node = ProxyNode(
            name: "vless",
            protocolType: .vless,
            server: "vless.example.com",
            port: 443,
            uuid: "00000000-0000-0000-0000-000000000006",
            tlsEnabled: true,
            sni: "edge.example.com",
            transport: TransportOptions(kind: .websocket, path: "/ws")
        )
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_180, clashPort: 51_181, secret: "test-secret")
        ))
        let binary = packageRoot.appending(path: "Vendor/sing-box/sing-box")
        let result = try await SingBoxProcess(binaryURL: binary).check(config: config)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    private var input: ConfigInput {
        ConfigInput(nodes: nodes, selectedNodeID: nodes[0].id, runtime: runtime)
    }

    private var runtime: RuntimeParameters {
        RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "runtime-secret")
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
            ),
            ProxyNode(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                sourceID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                name: "vl", protocolType: .vless, server: "vl.example.com", port: 443,
                uuid: "00000000-0000-0000-0000-000000000006", tlsEnabled: true,
                sni: "edge.example.com", flow: "xtls-rprx-vision", utlsFingerprint: "chrome",
                realityPublicKey: "public-key-placeholder", realityShortID: "0123456789abcdef"
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
