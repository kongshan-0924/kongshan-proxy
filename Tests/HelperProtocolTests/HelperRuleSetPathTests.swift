import XCTest
@testable import HelperProtocol

/// S2：限制 root sing-box 的**读**面。
///
/// 加固前 `route` 只做结构检查，App 被攻破后可让 root 读任意文件
///（`route.rule_set[].path`）。这里把本地 rule_set 锁进被钉死用户的 App 支持目录。
final class HelperRuleSetPathTests: XCTestCase {
    private let allowed = "/Users/tester/Library/Application Support/kongshan"

    // MARK: - 路径包含判定

    func testContainedPathIsAccepted() {
        XCTAssertTrue(HelperConfigWhitelist.isPathContained(allowed + "/rule-sets/geoip-cn.srs", in: allowed))
    }

    func testEscapeViaDotDotIsRejected() {
        XCTAssertFalse(
            HelperConfigWhitelist.isPathContained(allowed + "/rule-sets/../../../../etc/passwd", in: allowed),
            "前缀匹配得上但实际逃逸了，必须按 .. 段拒绝"
        )
    }

    func testUnrelatedAndRelativePathsAreRejected() {
        XCTAssertFalse(HelperConfigWhitelist.isPathContained("/etc/passwd", in: allowed))
        XCTAssertFalse(HelperConfigWhitelist.isPathContained("rule-sets/x.srs", in: allowed))
        // 同名前缀但不是子目录：/…/kongshan-evil 不能因为前缀像就放行。
        XCTAssertFalse(HelperConfigWhitelist.isPathContained(allowed + "-evil/x.srs", in: allowed))
    }

    // MARK: - 配置校验

    private func config(ruleSet: [[String: Any]]) -> Data {
        let root: [String: Any] = [
            "log": ["level": "info"],
            "dns": ["servers": [["type": "https", "tag": "doh", "server": "1.1.1.1", "path": "/dns-query"]]],
            "route": ["final": "手动选择", "rule_set": ruleSet],
            "inbounds": [["type": "tun", "auto_route": true]],
            "outbounds": [["type": "direct", "tag": "direct"]],
            "experimental": ["clash_api": [
                "external_controller": "127.0.0.1:31909",
                "secret": String(repeating: "s", count: 32)
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testLocalRuleSetInsideAllowedDirectoryPasses() {
        let data = config(ruleSet: [
            ["type": "local", "tag": "geoip-cn", "format": "binary", "path": allowed + "/rule-sets/geoip-cn.srs"]
        ])
        let result = HelperConfigWhitelist.validate(data, allowedRuleSetDirectory: allowed)
        XCTAssertTrue(result.ok, result.reason ?? "")
        XCTAssertEqual(result.ruleSetPaths.count, 1, "通过的路径要交回给 helper 做 realpath 复核")
    }

    func testRuleSetOutsideAllowedDirectoryIsRejected() {
        let data = config(ruleSet: [
            ["type": "local", "tag": "evil", "format": "binary", "path": "/etc/passwd"]
        ])
        XCTAssertFalse(HelperConfigWhitelist.validate(data, allowedRuleSetDirectory: allowed).ok)
    }

    /// remote rule_set 会变成「让 root 去连任意地址」的新入口；App 侧不生成，这里也不放行。
    func testRemoteRuleSetIsRejected() {
        let data = config(ruleSet: [["type": "remote", "tag": "x", "url": "http://evil.example/x.srs"]])
        XCTAssertFalse(HelperConfigWhitelist.validate(data, allowedRuleSetDirectory: allowed).ok)
    }

    /// 解析不出家目录时传 nil：退回结构校验，不因此拒绝启动 TUN。
    func testNilAllowedDirectoryKeepsLegacyBehaviour() {
        let data = config(ruleSet: [
            ["type": "local", "tag": "x", "format": "binary", "path": "/somewhere/else/x.srs"]
        ])
        XCTAssertTrue(HelperConfigWhitelist.validate(data).ok)
    }

    /// `dns.servers[].path` 是 DoH 的 **URL 路径**，不是文件路径——不能被这条加固误伤。
    func testDoHURLPathIsNotTreatedAsFilePath() {
        let data = config(ruleSet: [])
        XCTAssertTrue(HelperConfigWhitelist.validate(data, allowedRuleSetDirectory: allowed).ok)
    }
}
