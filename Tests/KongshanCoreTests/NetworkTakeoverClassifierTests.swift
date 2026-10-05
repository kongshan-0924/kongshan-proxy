import XCTest
@testable import KongshanCore

/// 网络自检「哪些服务算接管残留」。真机 2026-10-05 21:52：开着 TUN + 系统代理跑自检，
/// 4 个按预期指向 kongshan 的服务被报成残留，还建议用户手工清空——照做就把接管拆了。
final class NetworkTakeoverClassifierTests: XCTestCase {
    private let tun: Set<String> = ["172.19.0.1"]
    private let services = [
        NetworkServiceState(order: 1, name: "Wi-Fi", dnsServers: ["172.19.0.1"], proxyPort: 36_815),
        NetworkServiceState(order: 2, name: "Thunderbolt Bridge", dnsServers: ["172.19.0.1"], proxyPort: nil),
        NetworkServiceState(order: 3, name: "LAN", dnsServers: [], proxyPort: 36_815),
        NetworkServiceState(order: 4, name: "USB LAN", dnsServers: ["192.0.2.53"], proxyPort: nil),
    ]

    private func names(_ list: [NetworkServiceState]) -> [String] { list.map(\.name) }

    func testActiveTakeoverIsNotALeftover() {
        let left = NetworkTakeoverClassifier.leftovers(in: services, tunAddresses: tun, relayPort: 36_815,
                                                       tunActive: true, systemProxyActive: true)
        XCTAssertTrue(left.isEmpty)
        XCTAssertEqual(names(NetworkTakeoverClassifier.expected(in: services, tunAddresses: tun, relayPort: 36_815,
                                                                tunActive: true, systemProxyActive: true)),
                       ["Wi-Fi", "Thunderbolt Bridge", "LAN"])
    }

    func testEverythingPointingAtUsIsALeftoverWhenNotTakingOver() {
        let left = NetworkTakeoverClassifier.leftovers(in: services, tunAddresses: tun, relayPort: 36_815,
                                                       tunActive: false, systemProxyActive: false)
        XCTAssertEqual(names(left), ["Wi-Fi", "Thunderbolt Bridge", "LAN"])
    }

    /// 只开系统代理时，DNS 还指向 TUN 地址就是残留（2026-09-16 事故的形状）；代理指向中转端口是预期。
    func testOnlyTheInactiveModeCountsAsLeftover() {
        let left = NetworkTakeoverClassifier.leftovers(in: services, tunAddresses: tun, relayPort: 36_815,
                                                       tunActive: false, systemProxyActive: true)
        XCTAssertEqual(names(left), ["Wi-Fi", "Thunderbolt Bridge"])
        let tunOnly = NetworkTakeoverClassifier.leftovers(in: services, tunAddresses: tun, relayPort: 36_815,
                                                          tunActive: true, systemProxyActive: false)
        XCTAssertEqual(names(tunOnly), ["Wi-Fi", "LAN"])
    }

    func testUnknownRelayPortNeverMatchesProxies() {
        let left = NetworkTakeoverClassifier.leftovers(in: services, tunAddresses: [], relayPort: nil,
                                                       tunActive: false, systemProxyActive: false)
        XCTAssertTrue(left.isEmpty)
    }
}
