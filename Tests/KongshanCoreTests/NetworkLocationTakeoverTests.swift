import Foundation
import XCTest
@testable import KongshanCore
import HelperProtocol

/// macOS 的网络位置：每个位置一套同名网络服务，`networksetup` 只能读写当前位置。
///
/// 真机 2026-10-06 23:29:56 用户在接管（系统代理 + TUN）中从「自动」切到「手动网关」，5 秒后停止接管：
/// 旧实现把「自动」里拍的快照按服务名写进了「手动网关」（Wi-Fi 的 DNS 被清空，整机断网，重启无效），
/// 「自动」里指向空山的代理与 TUN DNS 却没人还原——自检只看当前位置，连报三次「接管残留：ok」。
/// 这组测试锁定：快照按位置记、只还原当前位置、切换后补挂先采新位置原值、切回去时还原。
final class NetworkLocationTakeoverTests: XCTestCase {
    private let automatic = NetworkLocation(id: "AUTO-SET", name: "Automatic")
    private let softRouter = NetworkLocation(id: "SOFT-SET", name: "手动网关")
    private let tunDNS = "172.19.0.1"
    private let relayPort = 36815

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-location-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 与真机同形：「自动」里 Wi-Fi 跟随 DHCP、另有 LAN；「手动网关」里 Wi-Fi 手动指向网关的 DNS。
    private func incidentNetwork() -> LocationNetworkSimulator {
        LocationNetworkSimulator(
            locations: [automatic, softRouter],
            current: automatic.id,
            dns: [
                automatic.id: ["Wi-Fi": [], "LAN": []],
                softRouter.id: ["Wi-Fi": ["192.0.2.53"], "USB 10/100/1000 LAN": []]
            ]
        )
    }

    private func managers(_ sim: LocationNetworkSimulator, root: URL) -> (SystemProxyManager, SystemDNSManager) {
        let storage = Storage(rootDirectory: root)
        return (
            SystemProxyManager(storage: storage, runner: sim.run(arguments:timeout:), locations: sim.provider),
            SystemDNSManager(storage: storage, runner: sim.run(arguments:timeout:), locations: sim.provider)
        )
    }

    // MARK: - 事故复现：接管中切位置、随即停止

    func testStopAfterSwitchingLocationLeavesNewLocationUntouchedAndRestoresOldOneOnReturn() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        let (proxy, dns) = managers(sim, root: root)

        try await proxy.enable(port: relayPort)
        try await dns.enable(server: tunDNS)
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [tunDNS])
        XCTAssertTrue(sim.proxy(automatic.id, "Wi-Fi").http.enabled)

        // 切到「手动网关」，没来得及补挂就停止接管。
        sim.switchTo(softRouter.id)
        let proxyOutcome = try await proxy.restore()
        let dnsOutcome = try await dns.restore()

        XCTAssertEqual(sim.dns(softRouter.id, "Wi-Fi"), ["192.0.2.53"], "绝不能把「自动」的空 DNS 写进「手动网关」")
        XCTAssertEqual(sim.mutations(in: softRouter.id), [], "停止时「手动网关」一条设置都不该被写")
        XCTAssertEqual(proxyOutcome.restored, [])
        XCTAssertEqual(dnsOutcome.restored, [])
        XCTAssertEqual(dnsOutcome.elsewhere, [PendingLocationRestore(locationID: automatic.id, locationName: "Automatic", services: ["LAN", "Wi-Fi"])])
        XCTAssertEqual(proxyOutcome.elsewhere.map(\.locationID), [automatic.id])
        XCTAssertEqual(dnsOutcome.elsewhere.first?.summary, "位置「自动」：LAN、Wi-Fi")
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [tunDNS], "「自动」此刻改不到，残留还在——所以快照必须留着")

        // 切回「自动」：按快照还原那里的原值，快照删除。
        sim.switchTo(automatic.id)
        let proxyBack = try await proxy.recoverIfNeeded()
        let dnsBack = try await dns.recoverIfNeeded()
        XCTAssertEqual(Set(dnsBack.restored), ["Wi-Fi", "LAN"])
        XCTAssertEqual(Set(proxyBack.restored), ["Wi-Fi", "LAN"])
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [])
        XCTAssertEqual(sim.dns(automatic.id, "LAN"), [])
        XCTAssertFalse(sim.proxy(automatic.id, "Wi-Fi").http.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.recoveryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dns.recoveryURL.path))
    }

    // MARK: - 接管中切位置：补挂先采新位置的原值

    func testReassertAfterSwitchRecordsNewLocationOriginalsSoStopRestoresEachLocationToItsOwnValues() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        let (proxy, dns) = managers(sim, root: root)

        try await proxy.enable(port: relayPort)
        try await dns.enable(server: tunDNS)
        sim.switchTo(softRouter.id)
        try await proxy.reassert(port: relayPort)
        try await dns.reassert(server: tunDNS)

        XCTAssertEqual(sim.dns(softRouter.id, "Wi-Fi"), [tunDNS, "192.0.2.53"], "新位置也要劫持 DNS，用户原有的保留在后")
        XCTAssertTrue(sim.proxy(softRouter.id, "Wi-Fi").http.enabled)
        let snapshot = try JSONDecoder().decode(DNSRecoverySnapshot.self, from: Data(contentsOf: dns.recoveryURL))
        XCTAssertEqual(
            Set(snapshot.services.map { "\($0.locationID ?? "-")|\($0.name)|\($0.servers.joined(separator: ","))" }),
            ["AUTO-SET|Wi-Fi|", "AUTO-SET|LAN|", "SOFT-SET|Wi-Fi|192.0.2.53", "SOFT-SET|USB 10/100/1000 LAN|"]
        )

        // 在「手动网关」停止：「手动网关」回到它自己的原值。
        _ = try await proxy.restore()
        let outcome = try await dns.restore()
        XCTAssertEqual(sim.dns(softRouter.id, "Wi-Fi"), ["192.0.2.53"])
        XCTAssertFalse(sim.proxy(softRouter.id, "Wi-Fi").http.enabled)
        XCTAssertEqual(Set(outcome.restored), ["Wi-Fi", "USB 10/100/1000 LAN"])
        XCTAssertEqual(outcome.elsewhere.map(\.locationID), [automatic.id])

        // 切回「自动」：「自动」回到它自己的原值。
        sim.switchTo(automatic.id)
        _ = try await proxy.recoverIfNeeded()
        _ = try await dns.recoverIfNeeded()
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [])
        XCTAssertFalse(sim.proxy(automatic.id, "LAN").socks.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dns.recoveryURL.path))
    }

    /// 切回原位置时那里的服务还指着我们（接管中本就该如此），补挂不该动它，也不该重采它的「原值」。
    func testReassertBackInOriginalLocationKeepsItsOriginalSnapshot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        let (proxy, dns) = managers(sim, root: root)
        try await proxy.enable(port: relayPort)
        try await dns.enable(server: tunDNS)
        sim.switchTo(softRouter.id)
        try await dns.reassert(server: tunDNS)
        sim.switchTo(automatic.id)
        let before = sim.mutations.count
        try await proxy.reassert(port: relayPort)
        try await dns.reassert(server: tunDNS)
        XCTAssertEqual(sim.mutations.count, before, "原位置仍由我们接管着，一条都不用写")

        _ = try await dns.restore()
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [], "还原成「自动」的原值，而不是「手动网关」的")
    }

    // MARK: - 增量短路不能跳过新位置

    /// 新位置的服务恰好指着我们（上次没还原掉的残留），快照里却没有它：切配置时不能走增量短路，
    /// 必须采集它；残留的「指向我们」不能当原值记。
    func testEnableInUncoveredLocationCapturesItInsteadOfShortCircuiting() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        let (proxy, _) = managers(sim, root: root)
        try await proxy.enable(port: relayPort)
        sim.switchTo(softRouter.id)
        sim.setProxy(softRouter.id, "Wi-Fi", onUs: true)
        sim.setProxy(softRouter.id, "USB 10/100/1000 LAN", onUs: true)

        try await proxy.enable(port: relayPort)

        let snapshot = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: Data(contentsOf: proxy.recoveryURL))
        let captured = try XCTUnwrap(snapshot.services.first { $0.locationID == softRouter.id && $0.name == "Wi-Fi" })
        XCTAssertFalse(captured.http.enabled, "指向我们的残留按「关」记，否则还原时会把残留写回去")
        XCTAssertTrue(snapshot.services.contains { $0.locationID == automatic.id && $0.name == "Wi-Fi" }, "原位置的项要带着")
        _ = try await proxy.restore()
        XCTAssertFalse(sim.proxy(softRouter.id, "Wi-Fi").http.enabled)
    }

    // MARK: - 兼容与清理

    /// 旧版本写的快照不知道位置：照旧按服务名还原（与改动前一致），不因升级卡住。
    func testLegacySnapshotWithoutLocationStillRestoresByName() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        sim.setDNS(automatic.id, "LAN", [tunDNS])
        let legacy = #"{"capturedAt":0,"services":[{"name":"LAN","servers":[]}],"version":1}"#
        try Data(legacy.utf8).write(to: root.appending(path: "dns-recovery.json"))
        let (_, dns) = managers(sim, root: root)

        sim.switchTo(softRouter.id)
        let away = try await dns.recoverIfNeeded()
        XCTAssertEqual(away.pending, ["LAN"], "LAN 只在「自动」里有：在别处是待还原")

        sim.switchTo(automatic.id)
        let back = try await dns.recoverIfNeeded()
        XCTAssertEqual(back.restored, ["LAN"])
        XCTAssertEqual(sim.dns(automatic.id, "LAN"), [])
    }

    func testEntriesOfDeletedLocationAreDropped() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        let orphan = #"{"capturedAt":0,"services":[{"locationID":"GONE-SET","locationName":"公司","name":"Wi-Fi","servers":[]}],"version":1}"#
        try Data(orphan.utf8).write(to: root.appending(path: "dns-recovery.json"))
        let (_, dns) = managers(sim, root: root)

        let outcome = try await dns.recoverIfNeeded()
        XCTAssertEqual(outcome.elsewhere, [], "位置已被删除，再也还原不到")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dns.recoveryURL.path))
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [], "更不能写进当前位置")
    }

    /// 读不到位置（偏好读取失败）时退回旧行为，不比改动前更糟。
    func testUnknownCurrentLocationFallsBackToRestoringByName() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = incidentNetwork()
        let storage = Storage(rootDirectory: root)
        let dns = SystemDNSManager(storage: storage, runner: sim.run(arguments:timeout:), locations: { nil })
        try await dns.enable(server: tunDNS)
        let outcome = try await dns.restore()
        XCTAssertEqual(Set(outcome.restored), ["Wi-Fi", "LAN"])
        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), [])
    }

    // MARK: - 读系统偏好

    func testParsesPreferencesWithLinkedServicesAndInactiveFlag() {
        let sets: [String: Any] = [
            "AUTO-SET": [
                "UserDefinedName": "Automatic",
                "Network": ["Service": [
                    "S1": ["__LINK__": "/NetworkServices/S1"],
                    "S2": ["__LINK__": "/NetworkServices/S2"]
                ]]
            ],
            "SOFT-SET": [
                "UserDefinedName": "手动网关",
                "Network": ["Service": ["S3": ["__LINK__": "/NetworkServices/S3"]]]
            ]
        ]
        let services: [String: Any] = [
            "S1": [
                "UserDefinedName": "Wi-Fi",
                "DNS": ["ServerAddresses": ["172.19.0.1"]],
                "Proxies": ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 36815, "SOCKSEnable": 0]
            ],
            "S2": ["Interface": ["UserDefinedName": "Thunderbolt Bridge"], "__INACTIVE__": 1],
            "S3": ["UserDefinedName": "Wi-Fi", "DNS": ["ServerAddresses": ["192.0.2.53"]]]
        ]
        let parsed = NetworkLocationsSnapshot.parse(currentSet: "/Sets/SOFT-SET", sets: sets, networkServices: services)

        XCTAssertEqual(parsed.current, softRouter)
        XCTAssertEqual(parsed.locations.map(\.id), ["AUTO-SET", "SOFT-SET"])
        let autoWiFi = parsed.services.first { $0.location.id == "AUTO-SET" && $0.name == "Wi-Fi" }
        XCTAssertEqual(autoWiFi?.dnsServers, ["172.19.0.1"])
        XCTAssertEqual(autoWiFi?.http, ProxyEndpointState(enabled: true, server: "127.0.0.1", port: 36815))
        XCTAssertEqual(autoWiFi?.socks.enabled, false)
        let bridge = parsed.services.first { $0.name == "Thunderbolt Bridge" }
        XCTAssertEqual(bridge?.enabled, false, "名字取自网卡，禁用标记要认出来")

        let findings = NetworkLocationResidue.findings(in: parsed, relayPort: 36815, tunDNSAddresses: ["172.19.0.1"])
        XCTAssertEqual(findings, [.init(location: automatic, service: "Wi-Fi", proxy: true, dns: true)],
                       "只报非当前位置；当前位置由 networksetup 那条路径管")
        XCTAssertEqual(NetworkLocationResidue.describe(findings), "位置「自动」：Wi-Fi（代理、DNS）")
    }

    /// 只读真机偏好：位置与当前位置自洽。读不到（极少见）时不算失败。
    func testLiveReaderIsSelfConsistent() throws {
        guard let snapshot = NetworkLocationReader.live() else { throw XCTSkip("读不到系统网络偏好") }
        XCTAssertFalse(snapshot.locations.isEmpty)
        if let current = snapshot.current {
            XCTAssertTrue(snapshot.locations.contains(current))
        }
    }

    // MARK: - 特权助手的异常退出还原

    func testHelperRestoresOnlyEntriesOfCurrentLocation() {
        let snapshot = HelperDNSRestore.Snapshot(version: 1, services: [
            .init(name: "Wi-Fi", servers: [], locationID: "AUTO-SET"),
            .init(name: "Wi-Fi", servers: ["192.0.2.53"], locationID: "SOFT-SET"),
            .init(name: "LAN", servers: [])
        ])
        let commands = HelperDNSRestore.restoreArguments(
            snapshot: snapshot, knownServiceNames: ["Wi-Fi", "LAN"], currentLocationID: "SOFT-SET"
        )
        XCTAssertEqual(commands, [["-setdnsservers", "Wi-Fi", "192.0.2.53"], ["-setdnsservers", "LAN", "Empty"]])
        XCTAssertEqual(HelperNetworkLocation.currentSetID(fromCurrentSetValue: "/Sets/SOFT-SET"), "SOFT-SET")
        XCTAssertNil(HelperNetworkLocation.currentSetID(fromCurrentSetValue: "/Sets/../x"))
        XCTAssertNil(HelperNetworkLocation.currentSetID(fromCurrentSetValue: nil))
    }

    /// 助手解码 App 写的新格式快照（含位置字段）。
    func testHelperDecodesLocationTaggedSnapshotWrittenByApp() throws {
        let snapshot = DNSRecoverySnapshot(services: [
            DNSServiceSnapshot(name: "Wi-Fi", servers: [], locationID: "AUTO-SET", locationName: "Automatic")
        ])
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(HelperDNSRestore.Snapshot.self, from: data)
        XCTAssertEqual(decoded.services, [.init(name: "Wi-Fi", servers: [], locationID: "AUTO-SET")])
    }
}

/// 多个网络位置的 `networksetup` 模拟：每个位置一套同名服务，读写只作用于当前位置。
final class LocationNetworkSimulator: @unchecked Sendable {
    struct ProxyState: Equatable {
        var http: ProxyEndpointState
        var https: ProxyEndpointState
        var socks: ProxyEndpointState
        var bypass: [String]

        static let off = ProxyState(
            http: ProxyEndpointState(enabled: false, server: "", port: 0),
            https: ProxyEndpointState(enabled: false, server: "", port: 0),
            socks: ProxyEndpointState(enabled: false, server: "", port: 0),
            bypass: []
        )
    }

    private let lock = NSLock()
    private let locations: [NetworkLocation]
    private var current: String
    private var serviceOrder: [String: [String]]
    private var dnsState: [String: [String: [String]]]
    private var proxyState: [String: [String: ProxyState]] = [:]
    private var log: [(location: String, arguments: [String])] = []

    init(locations: [NetworkLocation], current: String, dns: [String: [String: [String]]]) {
        self.locations = locations
        self.current = current
        dnsState = dns
        serviceOrder = dns.mapValues { $0.keys.sorted() }
    }

    func switchTo(_ id: String) { lock.withLock { current = id } }
    func dns(_ location: String, _ service: String) -> [String] { lock.withLock { dnsState[location]?[service] ?? [] } }
    func setDNS(_ location: String, _ service: String, _ servers: [String]) { lock.withLock { dnsState[location, default: [:]][service] = servers } }
    func proxy(_ location: String, _ service: String) -> ProxyState { lock.withLock { proxyState[location]?[service] ?? .off } }
    func setProxy(_ location: String, _ service: String, onUs: Bool) {
        lock.withLock {
            let endpoint = ProxyEndpointState(enabled: onUs, server: "127.0.0.1", port: 36815)
            proxyState[location, default: [:]][service] = ProxyState(http: endpoint, https: endpoint, socks: endpoint, bypass: [])
        }
    }
    var mutations: [[String]] { lock.withLock { log.filter { $0.arguments.first?.hasPrefix("-set") == true }.map(\.arguments) } }
    func mutations(in location: String) -> [[String]] {
        lock.withLock {
            log.filter { $0.location == location && $0.arguments.first?.hasPrefix("-set") == true }.map(\.arguments)
        }
    }

    var provider: NetworkLocationsProvider {
        { [self] in
            lock.withLock {
                NetworkLocationsSnapshot(
                    current: locations.first { $0.id == current },
                    locations: locations,
                    services: []
                )
            }
        }
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { handle(arguments) }
    }

    private func handle(_ arguments: [String]) -> ProcessResult {
        log.append((current, arguments))
        func ok(_ stdout: String = "") -> ProcessResult { ProcessResult(exitCode: 0, stdout: stdout, stderr: "") }
        func render(_ endpoint: ProxyEndpointState) -> String {
            "Enabled: \(endpoint.enabled ? "Yes" : "No")\nServer: \(endpoint.server)\nPort: \(endpoint.port)\nAuthenticated Proxy Enabled: 0\n"
        }
        guard let operation = arguments.first else { return ProcessResult(exitCode: 1, stdout: "", stderr: "missing") }
        let services = serviceOrder[current] ?? []
        let service = arguments.count > 1 ? arguments[1] : ""
        if operation != "-listallnetworkservices", !services.contains(service) {
            return ProcessResult(exitCode: 8, stdout: "** Error: Unable to find item in network database.", stderr: "")
        }
        var proxy = proxyState[current]?[service] ?? .off
        switch operation {
        case "-listallnetworkservices":
            return ok((["An asterisk (*) denotes that a network service is disabled."] + services).joined(separator: "\n"))
        case "-getdnsservers":
            let servers = dnsState[current]?[service] ?? []
            return ok(servers.isEmpty ? "There aren't any DNS Servers set on \(service).\n" : servers.joined(separator: "\n"))
        case "-setdnsservers":
            let values = Array(arguments.dropFirst(2))
            dnsState[current, default: [:]][service] = values == ["Empty"] ? [] : values
            return ok()
        case "-getwebproxy": return ok(render(proxy.http))
        case "-getsecurewebproxy": return ok(render(proxy.https))
        case "-getsocksfirewallproxy": return ok(render(proxy.socks))
        case "-getproxybypassdomains":
            return ok(proxy.bypass.isEmpty ? "There aren't any bypass domains set on \(service).\n" : proxy.bypass.joined(separator: "\n"))
        case "-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy":
            let endpoint = ProxyEndpointState(enabled: true, server: arguments[2], port: Int(arguments[3]) ?? 0)
            switch operation {
            case "-setwebproxy": proxy.http = endpoint
            case "-setsecurewebproxy": proxy.https = endpoint
            default: proxy.socks = endpoint
            }
        case "-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate":
            let enabled = arguments[2] == "on"
            switch operation {
            case "-setwebproxystate": proxy.http = ProxyEndpointState(enabled: enabled, server: proxy.http.server, port: proxy.http.port)
            case "-setsecurewebproxystate": proxy.https = ProxyEndpointState(enabled: enabled, server: proxy.https.server, port: proxy.https.port)
            default: proxy.socks = ProxyEndpointState(enabled: enabled, server: proxy.socks.server, port: proxy.socks.port)
            }
        case "-setproxybypassdomains":
            let values = Array(arguments.dropFirst(2))
            proxy.bypass = values == ["Empty"] ? [] : values
        default:
            return ok()
        }
        proxyState[current, default: [:]][service] = proxy
        return ok()
    }
}
