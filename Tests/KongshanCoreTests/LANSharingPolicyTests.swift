import Foundation
import Network
import XCTest
@testable import KongshanCore

/// 来源策略与速率换算。
final class LANSharingPolicyTests: XCTestCase {
    private func peer(_ address: String) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(address), port: 51234)
    }

    /// 基线是"必须私网"，白名单只在私网之内再收紧——**公网来源在任何配置下都不放行**。
    /// 绑 0.0.0.0 意味着端口跟着每一张网卡走，机器拿到公网 IP 时没有这条基线
    /// 就等于把开放代理挂到了互联网上。
    func testPublicPeersRejectedRegardlessOfAllowlist() {
        let open = LANPeerPolicy()
        let wide = LANPeerPolicy(allowedCIDRs: ["0.0.0.0/0"])
        for address in ["8.8.8.8", "1.1.1.1", "203.0.113.9", "172.15.0.1", "172.32.0.1"] {
            XCTAssertFalse(open.allows(peer(address)), address)
            XCTAssertFalse(wide.allows(peer(address)), "白名单再宽也不能放公网：\(address)")
        }
    }

    func testEmptyAllowlistAcceptsAnyPrivatePeer() {
        let policy = LANPeerPolicy()
        for address in ["10.0.0.5", "172.16.0.1", "172.31.255.254", "192.168.1.100", "127.0.0.1"] {
            XCTAssertTrue(policy.allows(peer(address)), address)
        }
    }

    func testAllowlistNarrowsWithinPrivateSpace() {
        let policy = LANPeerPolicy(allowedCIDRs: ["192.168.1.0/24", "10.0.0.7"])
        XCTAssertTrue(policy.allows(peer("192.168.1.1")))
        XCTAssertTrue(policy.allows(peer("192.168.1.254")))
        XCTAssertTrue(policy.allows(peer("10.0.0.7")))
        XCTAssertFalse(policy.allows(peer("192.168.2.1")), "邻网段不在白名单内")
        XCTAssertFalse(policy.allows(peer("10.0.0.8")), "单地址条目只匹配自己")
    }

    /// 白名单是 IPv4 语义；填了白名单还从 IPv6 进来的一律拒绝，
    /// 不能留一个白名单管不住的口子。
    func testIPv6RejectedOnceAllowlistIsSet() {
        XCTAssertTrue(LANPeerPolicy().allows(peer("fd00::1")))
        XCTAssertFalse(LANPeerPolicy(allowedCIDRs: ["192.168.1.0/24"]).allows(peer("fd00::1")))
        // IPv4 映射地址按其 IPv4 部分判定，能被白名单正常覆盖。
        XCTAssertTrue(LANPeerPolicy(allowedCIDRs: ["192.168.1.0/24"]).allows(peer("::ffff:192.168.1.5")))
    }

    func testCIDRParsingRejectsMalformedEntries() {
        for bad in ["", "abc", "192.168.1.0/33", "192.168.1.0/-1", "192.168.1", "999.1.1.1"] {
            XCTAssertFalse(LANPeerPolicy.matches("192.168.1.1", cidr: bad), "不该匹配：\(bad)")
        }
    }

    /// 第一次见到某客户端时不能把累计量当成瞬时速率报出去。
    func testRateNeedsTwoSamples() {
        var tracker = LANClientRateTracker()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = LANClientStats(
            address: "192.168.1.5", activeConnections: 1,
            upload: 1_000_000, download: 5_000_000, firstSeenAt: t0, lastActiveAt: t0
        )
        let a = tracker.update([first], at: t0)
        XCTAssertEqual(a.first?.uploadRate, 0, "首次采样速率必须是 0")

        let second = LANClientStats(
            address: "192.168.1.5", activeConnections: 1,
            upload: 1_100_000, download: 5_400_000, firstSeenAt: t0, lastActiveAt: t0.addingTimeInterval(1)
        )
        let b = tracker.update([second], at: t0.addingTimeInterval(1))
        XCTAssertEqual(b.first?.uploadRate, 100_000)
        XCTAssertEqual(b.first?.downloadRate, 400_000)
    }

    /// 计数回退（条目被淘汰后重建）时按 0 算，不报负数。
    func testCounterRollbackDoesNotProduceNegativeRate() {
        var tracker = LANClientRateTracker()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = tracker.update([LANClientStats(address: "10.0.0.2", activeConnections: 1,
                                           upload: 9_000, download: 9_000,
                                           firstSeenAt: t0, lastActiveAt: t0)], at: t0)
        let after = tracker.update([LANClientStats(address: "10.0.0.2", activeConnections: 1,
                                                   upload: 10, download: 10,
                                                   firstSeenAt: t0, lastActiveAt: t0)],
                                   at: t0.addingTimeInterval(1))
        XCTAssertEqual(after.first?.uploadRate, 0)
        XCTAssertEqual(after.first?.downloadRate, 0)
    }

    func testSettingsValidation() {
        XCTAssertThrowsError(try LANSharingSettings(enabled: true, port: 80, allowedCIDRs: []).validated())
        XCTAssertThrowsError(try LANSharingSettings(enabled: true, port: 50000, allowedCIDRs: []).validated())
        XCTAssertThrowsError(try LANSharingSettings(enabled: true, port: 7890, allowedCIDRs: ["nope"]).validated())
        // 去重与去空白。
        let cleaned = try? LANSharingSettings(
            enabled: true, port: 7890,
            allowedCIDRs: [" 192.168.1.0/24 ", "192.168.1.0/24", ""]
        ).validated()
        XCTAssertEqual(cleaned?.allowedCIDRs, ["192.168.1.0/24"])
    }
}
