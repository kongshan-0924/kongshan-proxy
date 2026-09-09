import Foundation
import XCTest
@testable import KongshanCore

/// 出口 IP 的信誉信息。
///
/// 数据源自称尚处测试阶段，所以两条性质必须钉住：
/// ①字段缺失只让那一项不显示，不能让整份解码失败；②拉取失败返回 nil，不能拖垮整份出口诊断。
final class IPReputationTests: XCTestCase {
    /// 真机 2026-09-09 实测返回的形状。
    private static let live = Data("""
    {
        "ip": "23.249.17.76",
        "asn": 400618,
        "asOrganization": "Prime Security Corp.",
        "country": "Japan",
        "countryCode": "JP",
        "region": "Tokyo",
        "city": "Tokyo",
        "fraudScore": 57,
        "isResidential": false,
        "isBroadcast": true,
        "userAgent": "curl/8.7.1"
    }
    """.utf8)

    func testDecodesLiveShape() async throws {
        let payload = Self.live
        let fetched = await IPReputationService.fetch { _ in payload }
        let info = try XCTUnwrap(fetched)
        XCTAssertEqual(info.ip, "23.249.17.76")
        XCTAssertEqual(info.fraudScore, 57)
        XCTAssertEqual(info.isResidential, false)
        XCTAssertEqual(info.isBroadcast, true)
        XCTAssertEqual(info.asnText, "AS400618 - Prime Security Corp.")
        XCTAssertEqual(info.labels, ["机房 IP", "广播 IP"])
        XCTAssertEqual(info.risk, .medium)
    }

    /// 字段少一半照样能用——只是少显示几项。
    func testPartialPayloadStillDecodes() async throws {
        let partial = Data(#"{"ip":"1.2.3.4","fraudScore":12}"#.utf8)
        let fetched = await IPReputationService.fetch { _ in partial }
        let info = try XCTUnwrap(fetched)
        XCTAssertEqual(info.risk, .low)
        XCTAssertNil(info.asnText)
        XCTAssertTrue(info.labels.isEmpty, "没有 isResidential/isBroadcast 就不该编标签")
    }

    /// 拉取失败、或返回的根本不是这个结构时，返回 nil；调用方据此跳过整块显示。
    func testFailuresYieldNilInsteadOfThrowing() async {
        let thrown = await IPReputationService.fetch { _ in throw IPReputationError.badResponse }
        XCTAssertNil(thrown)
        let garbage = await IPReputationService.fetch { _ in Data("<html>404</html>".utf8) }
        XCTAssertNil(garbage)
    }

    /// 分档要与数据源口径一致：它把 57~60 标为「中度风险」。
    func testRiskThresholdsMatchTheSourceWording() {
        XCTAssertEqual(IPRiskLevel(fraudScore: 0), .low)
        XCTAssertEqual(IPRiskLevel(fraudScore: 29), .low)
        XCTAssertEqual(IPRiskLevel(fraudScore: 30), .medium)
        XCTAssertEqual(IPRiskLevel(fraudScore: 57), .medium)
        XCTAssertEqual(IPRiskLevel(fraudScore: 60), .medium)
        XCTAssertEqual(IPRiskLevel(fraudScore: 69), .medium)
        XCTAssertEqual(IPRiskLevel(fraudScore: 70), .high)
        XCTAssertEqual(IPRiskLevel(fraudScore: 100), .high)
    }

    func testResidentialLabel() {
        let info = IPReputationInfo(isResidential: true, isBroadcast: false)
        XCTAssertEqual(info.labels, ["住宅 IP"])
    }
}
