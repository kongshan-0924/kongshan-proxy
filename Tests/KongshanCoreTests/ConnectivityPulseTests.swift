import Foundation
import XCTest
@testable import KongshanCore

/// 连通性脉搏：DNS 突发告警靠它区分「解析器坏了」与「整机断网」。
/// 真机 2026-10-05 04:00 外网断了约 1.5 分钟，旧判据（网卡收发量）因局域网流量误判成「链路正常」。
final class ConnectivityPulseTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_790_000_000)

    private func attempt(_ id: Int, direct: Bool) -> CoreLogLine {
        CoreLogLine.parse("[\(id) 1ms] outbound/\(direct ? "direct[direct]" : "vless[node-placeholder]"): outbound connection to x\(id).example.invalid:443")
    }

    private func failure(_ id: Int, direct: Bool) -> CoreLogLine {
        CoreLogLine.parse("[\(id) 5.0s] connection: open connection to x\(id).example.invalid:443 using "
            + "outbound/\(direct ? "direct[direct]" : "vless[node-placeholder]"): dial tcp 203.0.113.9:443: i/o timeout")
    }

    func testAttemptsAreCountedOncePerConnectionAndFailuresLandInTheirBucket() {
        var pulse = ConnectivityPulse()
        // 内核对节点连接写两行「outbound connection to」（拨号开始与成功），只算一次尝试。
        pulse.ingest(attempt(1, direct: false), at: origin)
        pulse.ingest(attempt(1, direct: false), at: origin.addingTimeInterval(0.3))
        pulse.ingest(attempt(2, direct: true), at: origin)
        pulse.ingest(failure(2, direct: true), at: origin.addingTimeInterval(5))
        pulse.ingest(failure(2, direct: true), at: origin.addingTimeInterval(5))
        let (direct, proxied) = pulse.tallies(from: origin, to: origin.addingTimeInterval(10))
        XCTAssertEqual(direct, .init(attempts: 1, failures: 1))
        XCTAssertEqual(proxied, .init(attempts: 1, failures: 0))
    }

    func testRuleRejectionsAndUnrelatedLinesAreIgnored() {
        var pulse = ConnectivityPulse()
        pulse.ingest(CoreLogLine.parse("[3 1ms] connection: open connection to ads.example.invalid:443 using outbound/block[reject]: operation not permitted"), at: origin)
        pulse.ingest(CoreLogLine.parse("[4 1ms] inbound/mixed[mixed-in]: inbound connection to a.example.invalid:443"), at: origin)
        let (direct, proxied) = pulse.tallies(from: origin, to: origin.addingTimeInterval(60))
        XCTAssertEqual(direct, .init())
        XCTAssertEqual(proxied, .init())
    }

    func testOnlyTheRequestedSpanIsCountedAndOldBucketsArePruned() {
        var pulse = ConnectivityPulse()
        pulse.ingest(failure(1, direct: true), at: origin)
        pulse.ingest(failure(2, direct: true), at: origin.addingTimeInterval(120))
        XCTAssertEqual(pulse.tallies(from: origin.addingTimeInterval(110), to: origin.addingTimeInterval(130)).direct.failures, 1)
        // 15 分钟后的新行会把最早那格清掉。
        pulse.ingest(failure(3, direct: true), at: origin.addingTimeInterval(16 * 60))
        XCTAssertEqual(pulse.tallies(from: origin, to: origin.addingTimeInterval(20)).direct.failures, 0)
    }

    func testClassification() {
        typealias T = ConnectivityPulse.Tally
        // 04:00 那次：直连与节点都在超时。
        XCTAssertEqual(DNSStallCause.classify(direct: T(attempts: 20, failures: 20), proxied: T(attempts: 14, failures: 14)), .networkDown)
        // 只开系统代理时直连样本可能为 0 或很少——直连在失败、节点无样本，也是本机。
        XCTAssertEqual(DNSStallCause.classify(direct: T(attempts: 5, failures: 4), proxied: T()), .networkDown)
        // 只有节点在失败：是节点或线路，不能说成整机断网，也不能说成解析器。
        XCTAssertEqual(DNSStallCause.classify(direct: T(attempts: 10, failures: 0), proxied: T(attempts: 10, failures: 9)), .undetermined)
        // 建连都正常：是解析器。
        XCTAssertEqual(DNSStallCause.classify(direct: T(attempts: 8, failures: 0), proxied: T(attempts: 30, failures: 1)), .resolver)
        // 样本太少：不下结论。
        XCTAssertEqual(DNSStallCause.classify(direct: T(attempts: 1, failures: 1), proxied: T(attempts: 2, failures: 0)), .undetermined)
    }
}
