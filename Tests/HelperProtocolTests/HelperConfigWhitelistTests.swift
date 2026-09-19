import XCTest
@testable import HelperProtocol

/// 配置内容白名单（纵深防御）纯逻辑单测。
/// 覆盖放行 + 每个拒绝分支，锁死 schema：App 被攻破后塞武器化配置时 helper 必须拒。
final class HelperConfigWhitelistTests: XCTestCase {
    private func json(_ dict: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: dict)
    }

    private func validConfig(
        outbounds: [[String: Any]] = [["type": "direct", "tag": "direct"]],
        inbounds: [[String: Any]] = [[
            "type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"],
            "auto_route": true
        ]],
        experimental: [String: Any] = [
            "clash_api": [
                "external_controller": "127.0.0.1:31909",
                "secret": "0123456789abcdef"
            ]
        ]
    ) -> [String: Any] {
        [
            "dns": ["servers": []],
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": ["rules": [], "final": "direct"],
            "experimental": experimental
        ]
    }

    // MARK: - 放行

    func testAcceptsMinimalValidConfig() {
        let config = validConfig(
            outbounds: [
                ["type": "direct", "tag": "direct"],
                ["type": "block", "tag": "reject"]
            ]
        )
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertTrue(result.ok, "合法配置应放行")
        XCTAssertNil(result.reason)
    }

    func testAcceptsAllWhitelistedOutboundTypes() {
        let config = validConfig(
            outbounds: HelperConfigWhitelist.allowedOutboundTypes.map { ["type": $0] }
        )
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertTrue(result.ok, "白名单内所有协议类型都应放行")
    }

    func testRejectsConfigWithoutOutboundsOrInbounds() {
        let config: [String: Any] = ["route": ["final": "direct"]]
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertFalse(result.ok)
    }

    // MARK: - 拒绝：非 JSON / 非对象

    func testRejectsInvalidJSON() {
        let result = HelperConfigWhitelist.validate(Data("not json".utf8))
        XCTAssertFalse(result.ok)
        XCTAssertNotNil(result.reason)
    }

    func testRejectsJSONArray() {
        let result = HelperConfigWhitelist.validate(Data("[1,2,3]".utf8))
        XCTAssertFalse(result.ok, "顶层数组应拒绝")
    }

    // MARK: - 拒绝：outbound 类型不在白名单

    func testRejectsUnknownOutboundType() {
        let config = validConfig(
            outbounds: [
                ["type": "tor", "tag": "evil"]  // tor 不在白名单
            ]
        )
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.reason?.contains("tor") == true, "拒绝原因应提到 tor")
    }

    func testRejectsOutboundMissingType() {
        let config = validConfig(outbounds: [["tag": "no-type"]])
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.reason?.contains("missing type") == true)
    }

    // MARK: - 拒绝：inbound 类型不在白名单

    func testRejectsUnknownInboundType() {
        let config = validConfig(
            inbounds: [["type": "http", "tag": "evil"]]  // http 不在白名单（只允许 mixed/tun）
        )
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.reason?.contains("http") == true)
    }

    // MARK: - 拒绝：clash_api（核心防御——防远程无鉴权控制 root sing-box）

    func testRejectsClashAPIExternalController() {
        // 攻击场景：App 被攻破后塞 clash_api，bind 0.0.0.0:9090 无 secret
        // → 攻击者远程改出站/MITM 全部流量。helper 必须拒。
        let config = validConfig(
            experimental: [
                "clash_api": ["external_controller": "0.0.0.0:9090"]
            ]
        )
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertFalse(result.ok, "远程或无鉴权 clash_api 必须拒绝")
        XCTAssertTrue(result.reason?.contains("clash_api") == true)
    }

    func testRejectsClashAPIWithoutSecretEvenOnLoopback() {
        let config = validConfig(
            experimental: [
                "clash_api": ["external_controller": "127.0.0.1:31909"]
            ]
        )
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertFalse(result.ok)
    }

    func testRejectsLogOutputAndMixedNonLoopback() {
        var logConfig = validConfig()
        logConfig["log"] = ["level": "info", "output": "/etc/kongshan.log"]
        XCTAssertFalse(HelperConfigWhitelist.validate(json(logConfig)).ok)

        let mixedConfig = validConfig(inbounds: [
            ["type": "tun", "auto_route": true],
            ["type": "mixed", "listen": "0.0.0.0", "listen_port": 51908]
        ])
        XCTAssertFalse(HelperConfigWhitelist.validate(json(mixedConfig)).ok)
    }

    func testSanitizesCachePathIntoRootOwnedDirectory() throws {
        let config = validConfig(experimental: [
            "clash_api": [
                "external_controller": "127.0.0.1:31909",
                "secret": "0123456789abcdef"
            ],
            "cache_file": [
                "enabled": true,
                "path": "/tmp/attacker-controlled.db",
                "store_fakeip": true
            ]
        ])
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertTrue(result.ok)
        let sanitized = try XCTUnwrap(result.sanitizedData)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let cache = try XCTUnwrap(experimental["cache_file"] as? [String: Any])
        XCTAssertEqual(
            cache["path"] as? String,
            HelperConstants.stateDirectory + "/fakeip-cache-v2.db"
        )
    }

    // MARK: - 真实生成器产物放行（回归）

    func testAcceptsRealisticGeneratedConfig() {
        // 模拟 ConfigGenerator 真实产物结构（含 selector/urltest/hysteria2/tun/fakeip/cache_file）。
        let config: [String: Any] = [
            "log": ["level": "info"],
            "dns": [
                "servers": [
                    ["type": "udp", "tag": "dns-udp"],
                    ["type": "fakeip", "tag": "dns-fakeip"]
                ]
            ],
            "inbounds": [
                ["type": "mixed", "tag": "mixed-in", "listen": "127.0.0.1", "listen_port": 31080],
                ["type": "tun", "tag": "tun-in", "address": ["172.19.0.1/30"], "auto_route": true]
            ],
            "outbounds": [
                ["type": "hysteria2", "tag": "node-abc", "server": "1.2.3.4", "server_port": 443],
                ["type": "selector", "tag": "手动选择", "outbounds": ["node-abc"], "default": "node-abc"],
                ["type": "urltest", "tag": "自动选择", "outbounds": ["node-abc"]],
                ["type": "direct", "tag": "direct"],
                ["type": "block", "tag": "reject"]
            ],
            "route": [
                "rules": [["outbound": "direct", "domain": ["localhost"]]],
                "final": "手动选择",
                "auto_detect_interface": true
            ],
            "experimental": [
                "clash_api": [
                    "external_controller": "127.0.0.1:31909",
                    "secret": "0123456789abcdef"
                ],
                "cache_file": [
                    "enabled": true,
                    "path": "/Users/x/Library/Application Support/kongshan/fakeip-cache-v2.db",
                    "store_fakeip": true
                ]
            ]
        ]
        let result = HelperConfigWhitelist.validate(json(config))
        XCTAssertTrue(result.ok, "生成器真实产物应放行：\(result.reason ?? "")")
    }
}
