import KongshanCore
import XCTest
@testable import kongshan

/// 连接页「规则 · 链路」列的文案。
///
/// 这一列宽度有限且用 `.truncationMode(.middle)`，多一个没信息量的词，
/// 被挤掉的就是真正要看的那一个。
final class ConnectionChainTextTests: XCTestCase {
    private func detail(chains: [String], rule: String = "RuleSet(ai)") -> ConnectionLiveDetail {
        ConnectionLiveDetail(
            connection: ConnectionDetail(payload: [
                "id": "c1",
                "metadata": ["host": "api.anthropic.com", "network": "tcp"],
                "rule": rule,
                "rulePayload": "",
                // 内核给的是「最终 → 入站」倒序，解析时会反转。
                "chains": Array(chains.reversed()),
                "upload": 0,
                "download": 0
            ]),
            uploadRate: 0,
            downloadRate: 0
        )
    }

    /// 入站标签每条连接都一样，不该占用这一列的宽度。
    func testInboundTagIsDropped() {
        let text = ConnectionsView.chainDisplayText(
            detail(chains: ["mixed-in", "🤖 AI 服务", "node-abc"]),
            nodeNames: ["node-abc": "🇭🇰 香港 IEPL 01"]
        )
        XCTAssertFalse(text.contains("mixed-in"), "入站标签不该出现：\(text)")
        XCTAssertTrue(text.contains("🤖 AI 服务"), "策略组名必须完整保留：\(text)")
        XCTAssertTrue(text.contains("🇭🇰 香港 IEPL 01"), "节点名必须换过来：\(text)")
    }

    func testTunInboundIsDroppedToo() {
        let text = ConnectionsView.chainDisplayText(
            detail(chains: ["tun-in", "🚀 节点选择", "node-abc"]),
            nodeNames: ["node-abc": "🇯🇵 东京 BGP"]
        )
        XCTAssertFalse(text.contains("tun-in"), text)
        XCTAssertTrue(text.contains("🚀 节点选择"), text)
    }

    /// 只有一项时不能丢——丢完这一列就空了。
    func testLoneChainSurvivesEvenIfItLooksLikeAnInbound() {
        let text = ConnectionsView.chainDisplayText(
            detail(chains: ["mixed-in"]),
            nodeNames: [:]
        )
        XCTAssertTrue(text.contains("mixed-in"), text)
    }

    /// 直连链路里没有入站标签，原样保留。
    func testDirectChainIsUntouched() {
        let text = ConnectionsView.chainDisplayText(
            detail(chains: ["🎯 全球直连", "direct"], rule: "RuleSet(apple)"),
            nodeNames: [:]
        )
        XCTAssertTrue(text.contains("🎯 全球直连"), text)
        XCTAssertTrue(text.contains("direct"), text)
    }
}
