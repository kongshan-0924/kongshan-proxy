import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// 信誉信息是**可选增强**：它失败时出口诊断必须照常给出 IP、位置与 DNS 结论。
/// 这条断了不会有任何报错——只会在数据源抽风的那天，用户连出口 IP 都看不到了。
final class ExitReputationWiringTests: XCTestCase {
    private func makeService(reputation: IPReputationInfo?) -> ExitDiagnosticsService {
        ExitDiagnosticsService(
            loader: { request in
                let path = request.url?.path() ?? ""
                if path.hasSuffix("/config") {
                    return Data(#"{"dns_leak_domain":"leak.example","ipv4_url":"https://ipv4.example"}"#.utf8)
                }
                if path.hasSuffix("/json") {
                    return Data(#"{"ip":"203.0.113.9","country":"Japan","city":"Tokyo","organization":"Example Ltd"}"#.utf8)
                }
                return Data("[]".utf8)
            },
            reputationProvider: { reputation },
            now: { Date(timeIntervalSince1970: 1_820_000_000) }
        )
    }

    func testReportStillCompletesWhenReputationIsUnavailable() async throws {
        let report = try await makeService(reputation: nil).run(remoteDoH: "https://8.8.8.8/dns-query")
        XCTAssertEqual(report.exit.ip, "203.0.113.9")
        XCTAssertEqual(report.exit.location, "Tokyo, Japan")
        XCTAssertNil(report.reputation, "拿不到就该是 nil")
    }

    func testReputationIsCarriedIntoTheReport() async throws {
        let info = IPReputationInfo(
            ip: "203.0.113.9",
            asn: 400618,
            asOrganization: "Prime Security Corp.",
            fraudScore: 57,
            isResidential: false,
            isBroadcast: true
        )
        let report = try await makeService(reputation: info).run(remoteDoH: "https://8.8.8.8/dns-query")
        XCTAssertEqual(report.reputation?.fraudScore, 57)
        XCTAssertEqual(report.reputation?.risk, .medium)
        XCTAssertEqual(Theme.riskSummary(try XCTUnwrap(report.reputation)), "57% 中度风险 · 机房 IP · 广播 IP")
    }
}
