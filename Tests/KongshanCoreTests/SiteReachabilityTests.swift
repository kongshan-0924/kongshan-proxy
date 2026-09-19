import Foundation
import XCTest
@testable import KongshanCore

/// 站点可达性自测。**判据的核心是 `cf-mitigated`**：
/// 真机 2026-09-03～09-04，Codex 反复「正在重新连接」的真因就是 Cloudflare 对当前出口 IP
/// 回 403 + `cf-mitigated: challenge`，而界面上只显示"超时"，用户以为节点死了、反复换节点也没用。
/// 这一类必须与"节点不通"区分开，否则给出的建议是错的。
final class SiteReachabilityTests: XCTestCase {
    func testCloudflareChallengeIsItsOwnCategory() {
        let outcome = SiteReachabilityProbe.classify(
            statusCode: 403,
            headers: ["cf-mitigated": "challenge", "server": "cloudflare"]
        )
        XCTAssertEqual(outcome, .challenged(statusCode: 403, mitigation: "challenge"))
        XCTAssertFalse(outcome.isUsable)
    }

    /// 值可能变（现在是 challenge），存在这个头本身就说明被拦下做了缓解处理。
    func testAnyMitigationValueCounts() {
        XCTAssertEqual(
            SiteReachabilityProbe.classify(statusCode: 403, headers: ["cf-mitigated": "block"]),
            .challenged(statusCode: 403, mitigation: "block")
        )
        // 空值不算——那不是有效标记。
        XCTAssertEqual(
            SiteReachabilityProbe.classify(statusCode: 403, headers: ["cf-mitigated": ""]),
            .rejected(statusCode: 403)
        )
    }

    /// 401 说明请求**确实到达了服务端**（只是没登录），链路是通的。
    /// 真机上 `api.openai.com/v1/models` 正是回 401，那时链路完全正常。
    func testUnauthorizedMeansTheLinkWorks() {
        XCTAssertEqual(SiteReachabilityProbe.classify(statusCode: 401, headers: [:]), .ok(statusCode: 401))
        XCTAssertTrue(SiteReachabilityProbe.classify(statusCode: 401, headers: [:]).isUsable)
    }

    func testSuccessAndRedirectAreUsableAndOtherFailuresAreNot() {
        XCTAssertEqual(SiteReachabilityProbe.classify(statusCode: 204, headers: [:]), .ok(statusCode: 204))
        XCTAssertEqual(SiteReachabilityProbe.classify(statusCode: 302, headers: [:]), .ok(statusCode: 302))
        XCTAssertEqual(SiteReachabilityProbe.classify(statusCode: 503, headers: [:]), .rejected(statusCode: 503))
        XCTAssertFalse(SiteReachabilityProbe.classify(statusCode: 503, headers: [:]).isUsable)
    }

    /// 一个目标失败不许拖垮其余；结果顺序必须与传入顺序一致（界面按固定顺序展示）。
    func testOneFailureDoesNotAffectOthersAndOrderIsStable() async {
        let targets = (1...4).map {
            SiteProbeTarget(name: "T\($0)", url: URL(string: "https://example\($0).invalid")!, impact: "")
        }
        let results = await SiteReachabilityProbe.run(targets: targets) { request in
            guard request.url?.host() == "example2.invalid" else { return (200, [:]) }
            throw SiteProbeError.notHTTP
        }
        XCTAssertEqual(results.map(\.target.name), ["T1", "T2", "T3", "T4"])
        XCTAssertEqual(results[0].outcome, .ok(statusCode: 200))
        guard case .failed = results[1].outcome else { return XCTFail("T2 应为失败：\(results[1].outcome)") }
        XCTAssertEqual(results[3].outcome, .ok(statusCode: 200))
        XCTAssertNil(results[1].elapsedMilliseconds, "失败没有耗时可言")
        XCTAssertNotNil(results[0].elapsedMilliseconds)
    }

    /// 默认目标里必须同时有"会被挑战的站"和"基准站"，否则分不清是 IP 信誉问题还是整条链路不通。
    func testDefaultTargetsCoverBothChallengedSitesAndBaselines() {
        let names = SiteReachabilityProbe.defaultTargets.map(\.name)
        XCTAssertTrue(names.contains { $0.contains("ChatGPT") })
        XCTAssertTrue(names.contains("Claude"))
        XCTAssertTrue(names.contains("Google"), "需要一个非 Cloudflare 的基准")
        XCTAssertTrue(names.contains("Cloudflare"), "需要一个 Cloudflare 自家基准")
        for target in SiteReachabilityProbe.defaultTargets {
            XCTAssertFalse(target.impact.isEmpty, "\(target.name) 缺少后果说明，界面上没法解释")
        }
    }
}
