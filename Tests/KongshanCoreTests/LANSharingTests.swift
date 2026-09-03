import Foundation
import Network
import XCTest
@testable import KongshanCore

/// 局域网共享的来源过滤。
///
/// 绑 0.0.0.0 意味着这个端口跟着**每一张**网卡走。机器要是拿到公网 IP
/// （直连光猫、某些云主机或热点），不过滤就等于把一个开放代理挂到了互联网上——
/// 谁都能拿它当跳板，而流量与实名都记在用户头上。
final class LANSharingTests: XCTestCase {
    private func peer(_ address: String, port: UInt16 = 51234) -> NWEndpoint {
        .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!)
    }

    func testAcceptsPrivateIPv4Ranges() {
        for address in ["10.0.0.5", "10.255.255.254", "172.16.0.1", "172.31.255.254",
                        "192.168.1.100", "127.0.0.1", "169.254.10.20"] {
            XCTAssertTrue(LocalTCPRelay.isPrivatePeer(peer(address)), "应接受私网来源 \(address)")
        }
    }

    func testRejectsPublicIPv4() {
        // 172.15 与 172.32 在 172.16/12 之外——边界最容易写错，专门钉住。
        for address in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1",
                        "11.0.0.1", "192.167.1.1", "203.0.113.9"] {
            XCTAssertFalse(LocalTCPRelay.isPrivatePeer(peer(address)), "应拒绝公网来源 \(address)")
        }
    }

    func testHandlesIPv6() {
        XCTAssertTrue(LocalTCPRelay.isPrivatePeer(peer("::1")), "IPv6 回环")
        XCTAssertTrue(LocalTCPRelay.isPrivatePeer(peer("fd00::1")), "唯一本地地址 fc00::/7")
        XCTAssertTrue(LocalTCPRelay.isPrivatePeer(peer("fe80::1")), "链路本地")
        XCTAssertFalse(LocalTCPRelay.isPrivatePeer(peer("2001:4860:4860::8888")), "公网 IPv6")
        // IPv4 映射地址要按其 IPv4 部分判定，否则公网来源会从这条缝里钻进来。
        XCTAssertTrue(LocalTCPRelay.isPrivatePeer(peer("::ffff:192.168.1.5")))
        XCTAssertFalse(LocalTCPRelay.isPrivatePeer(peer("::ffff:8.8.8.8")))
    }

    /// 非 host/port 端点（Unix socket、Bonjour 服务名）无法判定来源，一律不放行。
    func testRejectsNonHostPortEndpoints() {
        XCTAssertFalse(LocalTCPRelay.isPrivatePeer(.service(name: "x", type: "_http._tcp", domain: "local", interface: nil)))
        XCTAssertFalse(LocalTCPRelay.isPrivatePeer(.unix(path: "/tmp/x.sock")))
    }
}
