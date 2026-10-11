import Foundation
import XCTest
@testable import KongshanCore

/// 远端那一跳断了的节点：请求发出去却一直收不到回应，内核不报错。
/// 真机 2026-10-07 自建的「中转→家宽出口」节点约 14% 请求挂满 10 秒，两小时内核日志 0 条错误。
final class StalledConnectionDetectorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let node = "node-11111111-1111-1111-1111-111111111111"

    private func sample(
        _ id: String, tag: String? = nil, network: String = "tcp", port: Int? = 443,
        up: Int64 = 517, down: Int64 = 0, startedAgo: TimeInterval, at now: Date
    ) -> StalledConnectionDetector.Sample {
        .init(id: id, outboundTag: tag ?? node, network: network, port: port, upload: up, download: down,
              start: now.addingTimeInterval(-startedAgo))
    }

    func testThreeStalledHandshakesOnOneNodeAreReportedOnce() {
        var detector = StalledConnectionDetector()
        var now = t0
        XCTAssertEqual(detector.ingest([sample("a", startedAgo: 7, at: now), sample("ok", down: 4_000, startedAgo: 7, at: now)], at: now), [])
        now = t0.addingTimeInterval(15)
        XCTAssertEqual(detector.ingest([sample("b", startedAgo: 9, at: now)], at: now), [])
        now = t0.addingTimeInterval(30)
        let reports = detector.ingest([sample("c", startedAgo: 12, at: now)], at: now)
        XCTAssertEqual(reports.map(\.outboundTag), [node])
        XCTAssertEqual(reports.first?.stalled, 3)
        XCTAssertEqual(reports.first?.healthy, 1)

        // 报过就清零：同样的连接还挂着也不再重复报。
        now = t0.addingTimeInterval(45)
        XCTAssertEqual(detector.ingest([sample("c", startedAgo: 27, at: now)], at: now), [])
    }

    func testOnlyCountsTLSOverTCPThroughANodeAfterTheClientSpoke() {
        var detector = StalledConnectionDetector()
        let opened = t0.addingTimeInterval(-30)
        for round in 0..<5 {
            let at = t0.addingTimeInterval(Double(round) * 15)
            let samples: [StalledConnectionDetector.Sample] = [
                // 每拍都是新开的、还没到判定时间
                .init(id: "young-\(round)", outboundTag: node, network: "tcp", port: 443, upload: 517, download: 0, start: at.addingTimeInterval(-2)),
                // 客户端还没说话（预连接）
                .init(id: "silent", outboundTag: node, network: "tcp", port: 443, upload: 0, download: 0, start: opened),
                // UDP 不在判据里
                .init(id: "quic", outboundTag: node, network: "udp", port: 443, upload: 1_200, download: 0, start: opened),
                // 非 443：长轮询之类本来就会晚回
                .init(id: "http", outboundTag: node, network: "tcp", port: 80, upload: 300, download: 0, start: opened),
                // 不经节点
                .init(id: "direct", outboundTag: nil, network: "tcp", port: 443, upload: 517, download: 0, start: opened)
            ]
            XCTAssertEqual(detector.ingest(samples, at: at), [], "第 \(round) 拍")
        }
    }

    func testStallsOutsideTheWindowExpire() {
        var detector = StalledConnectionDetector()
        _ = detector.ingest([sample("a", startedAgo: 7, at: t0), sample("b", startedAgo: 7, at: t0)], at: t0)
        let later = t0.addingTimeInterval(StalledConnectionDetector.window + 60)
        XCTAssertEqual(detector.ingest([sample("c", startedAgo: 7, at: later)], at: later), [], "10 分钟前的两条不算数")
    }

    func testDiscardPendingDropsJudgementsDuringOutages() {
        var detector = StalledConnectionDetector()
        _ = detector.ingest([sample("a", startedAgo: 7, at: t0), sample("b", startedAgo: 7, at: t0)], at: t0)
        detector.discardPending()
        let later = t0.addingTimeInterval(15)
        XCTAssertEqual(detector.ingest([sample("c", startedAgo: 7, at: later)], at: later), [])
    }

    func testSampleTakesTheNodeFromTheChainAndThePortFromTheHost() {
        let detail = ConnectionDetail(payload: [
            "id": "x",
            "metadata": ["host": "www.example.com", "destinationPort": "443", "network": "tcp"],
            "chains": ["node-22222222-2222-2222-2222-222222222222", "🚀 节点选择", "🤖 AI 服务"],
            "upload": NSNumber(value: 600),
            "download": NSNumber(value: 0)
        ])
        let sample = StalledConnectionDetector.Sample(detail)
        XCTAssertEqual(sample.outboundTag, "node-22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(sample.port, 443)
        XCTAssertEqual(sample.upload, 600)

        let direct = StalledConnectionDetector.Sample(ConnectionDetail(payload: [
            "id": "y", "metadata": ["host": "www.example.cn", "destinationPort": "443"], "chains": ["direct"]
        ]))
        XCTAssertNil(direct.outboundTag)
    }
}
