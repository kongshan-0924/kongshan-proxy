import XCTest
@testable import KongshanCore

/// 日志行结构解析。样本按真机内核输出的形状构造。
final class CoreLogLineTests: XCTestCase {
    func testParsesOutboundConnectionLine() {
        let line = CoreLogLine.parse(
            "[3235370629 284ms] outbound/vless[node-abc]: outbound connection to chatgpt.com:443"
        )
        XCTAssertEqual(line.connectionID, "3235370629")
        XCTAssertEqual(line.host, "chatgpt.com:443")
        XCTAssertEqual(line.category, "outbound/vless")
        XCTAssertFalse(line.message.hasPrefix("["), "前缀已单独成字段，正文里不该再重复")
    }

    func testParsesInboundLine() {
        let line = CoreLogLine.parse("[49680683 0ms] inbound/mixed[mixed-in]: inbound connection to a.example.com:443")
        XCTAssertEqual(line.connectionID, "49680683")
        XCTAssertEqual(line.host, "a.example.com:443")
        XCTAssertEqual(line.category, "inbound/mixed")
    }

    /// 失败行是排查的主角，必须能抽出主机名——不然没法按域名筛。
    func testParsesFailureLineWithTrailingClause() {
        let line = CoreLogLine.parse(
            "[1524482931 10.0s] connection: open connection to claude.ai:443 using outbound/trojan[x]: lookup failed"
        )
        XCTAssertEqual(line.connectionID, "1524482931")
        XCTAssertEqual(line.host, "claude.ai:443")
    }

    func testParsesProcessLine() {
        let line = CoreLogLine.parse("[2531711102 3ms] router: found process path: /Applications/Foo.app/Foo")
        XCTAssertEqual(line.connectionID, "2531711102")
        XCTAssertEqual(line.category, "router")
        XCTAssertNil(line.host, "这行没有目标主机")
    }

    /// 没有前缀的行（如 `sing-box started`）不能因此丢失。
    func testKeepsUnprefixedLines() {
        let line = CoreLogLine.parse("sing-box started (0.00s)")
        XCTAssertNil(line.connectionID)
        XCTAssertEqual(line.message, "sing-box started (0.00s)")
    }

    /// `[node-abc]` 这种非数字方括号不能被当成连接 ID 吃掉，否则正文会被截断。
    func testDoesNotTreatNonNumericBracketAsConnectionID() {
        let raw = "[node-abc] something happened"
        let line = CoreLogLine.parse(raw)
        XCTAssertNil(line.connectionID)
        XCTAssertEqual(line.message, raw)
    }

    /// `to reject` 之类不是主机名，不能误抽。
    func testIgnoresNonHostAfterTo() {
        XCTAssertNil(CoreLogLine.parse("[1 0ms] routed to reject").host)
        XCTAssertNil(CoreLogLine.parse("switching to something").host)
    }

    func testHandlesEmptyAndWhitespace() {
        XCTAssertEqual(CoreLogLine.parse("").message, "")
        XCTAssertNil(CoreLogLine.parse("   ").connectionID)
    }

    func testClassifiesExpectedRuleRejectionWithoutHidingOtherPermissionErrors() {
        let expected = CoreLogLine.parse(
            "[1 0ms] connection: open connection to ads.example:443 using outbound/block[reject]: operation not permitted"
        )
        XCTAssertTrue(expected.isExpectedRuleRejection)

        let unexpected = CoreLogLine.parse(
            "[2 0ms] outbound/trojan[node]: operation not permitted"
        )
        XCTAssertFalse(unexpected.isExpectedRuleRejection)
    }

    func testClassifiesNetworkTransitionRootCausesCaseInsensitively() {
        for marker in [
            "missing default interface",
            "network is unreachable",
            "can't assign requested address",
            "use of closed network connection"
        ] {
            XCTAssertTrue(CoreLogLine.parse("dial failed: \(marker.uppercased())").isNetworkTransitionFailure)
        }
        XCTAssertFalse(CoreLogLine.parse("dial tcp: i/o timeout").isNetworkTransitionFailure)
    }
}
