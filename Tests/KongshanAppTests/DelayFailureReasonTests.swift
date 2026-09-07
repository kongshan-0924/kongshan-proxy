import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// 测速失败的原因必须能传到用户面前。
///
/// 界面上每一行只能显示"超时"两个字，而"代理没开时全部超时"最常见的真因是
/// **节点域名在本机解析不了**——用户看到满屏超时只会以为节点全死了，反复换节点也没用。
@MainActor
final class DelayFailureReasonTests: XCTestCase {
    func testDNSFailuresAreTranslatedIntoSomethingActionable() {
        for raw in [
            "DNSError: -65554",
            "The operation couldn’t be completed. nodename nor servname provided",
            "hostname could not be found"
        ] {
            XCTAssertEqual(
                AppState.readableDelayFailure(raw),
                "无法解析节点域名（本机 DNS 解析不了；代理未开启时常见）",
                "原始报错：\(raw)"
            )
        }
    }

    func testOtherCausesKeepTheirOwnWording() {
        XCTAssertEqual(AppState.readableDelayFailure("Connection refused"), "节点服务器拒绝连接")
        XCTAssertEqual(AppState.readableDelayFailure("No route to host"), "本机到该节点没有路由")
        XCTAssertEqual(AppState.readableDelayFailure("超时"), "握手超时（3 秒内没连上）")
        // 认不出来的原样透出，不许吞掉。
        XCTAssertEqual(AppState.readableDelayFailure("某种没见过的错误"), "某种没见过的错误")
    }
}
