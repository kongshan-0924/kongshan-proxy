import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// App 层接线：切换网络位置、其他位置的待还原提示、自检里的其他位置、残留清扫遇忙、切换节点后的出口刷新。
/// 真机 2026-10-06 23:29:56 接管中从「自动」切到「手动网关」后停止：「手动网关」被写坏、「自动」的残留没人管，
/// 自检只看当前位置。
@MainActor
final class NetworkLocationWiringTests: XCTestCase {
    private let automatic = NetworkLocation(id: "AUTO-SET", name: "Automatic")
    private let softRouter = NetworkLocation(id: "SOFT-SET", name: "手动网关")
    private let hijack = TunSettings.defaults.dnsServerAddress

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-location-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{\"testURL\":\"https://www.gstatic.com/generate_204\",\"proxyRelayPort\":36815}".utf8)
            .write(to: root.appending(path: "settings.json"))
        return root
    }

    private func makeState(root: URL, sim: AppLocationSimulator, locations: NetworkLocationsProvider? = nil)
        -> (AppState, SystemProxyManager, SystemDNSManager) {
        let storage = Storage(rootDirectory: root)
        let provider = locations ?? sim.provider
        let proxy = SystemProxyManager(storage: storage, runner: sim.run(arguments:timeout:), locations: provider)
        let dns = SystemDNSManager(storage: storage, runner: sim.run(arguments:timeout:), locations: provider)
        let state = AppState(
            storage: storage,
            subscriptionService: SubscriptionService(storage: storage) { _ in HTTPDownload(data: Data(), statusCode: 500) },
            systemProxyManager: proxy,
            systemDNSManager: dns,
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            networkLocations: provider,
            automaticallyInitialize: false
        )
        return (state, proxy, dns)
    }

    private func waitUntil(_ condition: () -> Bool, seconds: Double = 6) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("等待超时")
    }

    /// 停在「手动网关」后，「自动」里还留着指向 kongshan 的设置；切回「自动」时 App 自动按快照还原。
    func testSwitchingBackToLocationRestoresWhatWasLeftThere() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = AppLocationSimulator(locations: [automatic, softRouter], current: automatic.id, services: [
            automatic.id: ["LAN", "Wi-Fi"],
            softRouter.id: ["Wi-Fi"]
        ])
        sim.setDNS(softRouter.id, "Wi-Fi", ["192.0.2.53"])
        let (state, proxy, dns) = makeState(root: root, sim: sim)
        try await proxy.enable(port: 36815)
        try await dns.enable(server: hijack)
        sim.switchTo(softRouter.id)
        _ = try await proxy.restore()
        _ = try await dns.restore()

        await state.initialize()
        XCTAssertEqual(sim.dns(softRouter.id, "Wi-Fi"), ["192.0.2.53"], "启动时也不能把「自动」的原值写进「手动网关」")
        let notice = state.runtimeEvents.first { $0.title == "其他网络位置有待还原的系统 DNS" }
        XCTAssertNotNil(notice, "\(state.runtimeEvents.map(\.title))")
        XCTAssertTrue(notice?.detail?.contains("位置「自动」：LAN、Wi-Fi") == true, notice?.detail ?? "")

        await state.checkNetworkLocation()
        sim.switchTo(automatic.id)
        await state.checkNetworkLocation()
        XCTAssertTrue(state.runtimeEvents.contains { $0.title == "网络位置已切换" && $0.detail?.contains("「手动网关」→「自动」") == true })

        try await waitUntil { sim.dns(automatic.id, "Wi-Fi") == [] && !sim.proxyOnUs(automatic.id, "Wi-Fi") }
        XCTAssertEqual(sim.dns(automatic.id, "LAN"), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dns.recoveryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: proxy.recoveryURL.path))
    }

    /// 其他位置的待还原提示：同样的内容只报一次（跨启动也是），还原后清掉，再出现时重报。
    func testElsewhereNoticeIsRecordedOnceAndClearedWhenRestored() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = AppLocationSimulator(locations: [automatic, softRouter], current: softRouter.id, services: [:])
        let (state, _, _) = makeState(root: root, sim: sim)
        let pending = [PendingLocationRestore(locationID: automatic.id, locationName: "Automatic", services: ["Wi-Fi"])]
        func notices() -> Int { state.runtimeEvents.filter { $0.title == "其他网络位置有待还原的系统代理" }.count }

        await state.notePendingTakeover(kind: "系统代理", [], elsewhere: pending, trigger: "停止")
        await state.notePendingTakeover(kind: "系统代理", [], elsewhere: pending, trigger: "启动")
        XCTAssertEqual(notices(), 1)
        let level = state.runtimeEvents.first { $0.title == "其他网络位置有待还原的系统代理" }?.level
        XCTAssertEqual(level, .warning, "那个位置的网这会儿是坏的，要让用户看见")

        await state.notePendingTakeover(kind: "系统代理", [], elsewhere: [], trigger: "切换网络位置")
        await state.notePendingTakeover(kind: "系统代理", [], elsewhere: pending, trigger: "停止")
        XCTAssertEqual(notices(), 2)
    }

    /// 自检看得见其他位置：没在接管时那里还指向 kongshan 就是问题；只有一个位置时不出这一项。
    func testSelfCheckReportsResidueInOtherLocations() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let on = ProxyEndpointState(enabled: true, server: "127.0.0.1", port: 36815)
        let off = ProxyEndpointState(enabled: false, server: "", port: 0)
        let snapshot = NetworkLocationsSnapshot(current: softRouter, locations: [automatic, softRouter], services: [
            NetworkLocationService(location: automatic, name: "Wi-Fi", enabled: true, dnsServers: [hijack], http: on, https: on, socks: on),
            NetworkLocationService(location: automatic, name: "LAN", enabled: true, dnsServers: [hijack], http: off, https: off, socks: off),
            NetworkLocationService(location: softRouter, name: "Wi-Fi", enabled: true, dnsServers: ["192.0.2.53"], http: off, https: off, socks: off)
        ])
        let sim = AppLocationSimulator(locations: [automatic, softRouter], current: softRouter.id, services: [:])
        let (state, _, _) = makeState(root: root, sim: sim, locations: { snapshot })
        await state.initialize()

        let item = try XCTUnwrap(state.otherLocationsCheckItem())
        XCTAssertEqual(item.severity, .problem)
        XCTAssertTrue(item.detail.contains("位置「自动」：Wi-Fi（代理、DNS）、LAN（DNS）"), item.detail)

        let single = NetworkLocationsSnapshot(current: softRouter, locations: [softRouter], services: [])
        let (lone, _, _) = makeState(root: root, sim: sim, locations: { single })
        XCTAssertNil(lone.otherLocationsCheckItem())
    }

    /// 清扫撞上「另一项操作仍在执行」：短暂重试后照常清掉，不报警。
    func testResidueSweepWaitsOutBusyManagerSilently() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1".utf8).write(to: root.appending(path: "dns-takeover.marker"))
        let sim = AppLocationSimulator(locations: [automatic], current: automatic.id, services: [automatic.id: ["Wi-Fi"]])
        sim.setDNS(automatic.id, "Wi-Fi", [hijack, "1.1.1.1"])
        let (state, _, dns) = makeState(root: root, sim: sim)
        await state.initialize()
        sim.setDNS(automatic.id, "Wi-Fi", [hijack, "1.1.1.1"])

        // 让 DNS 管理器忙一会儿（另一次清扫列服务卡 0.8 秒），同时触发清扫。
        sim.delayListing(by: .milliseconds(800))
        let server = hijack
        let holder = Task { try? await dns.sweepResidue(server: server) }
        try await Task.sleep(for: .milliseconds(100))
        sim.delayListing(by: nil)
        _ = await state.sweepTakeoverResidue(trigger: "测试")
        _ = await holder.value

        XCTAssertEqual(sim.dns(automatic.id, "Wi-Fi"), ["1.1.1.1"])
        XCTAssertFalse(state.warnings.contains { $0.contains("残留失败") }, "撞上自己的另一项操作不该报警：\(state.warnings)")
    }

    // MARK: - 切换节点后的出口

    private func report(_ ip: String) -> ExitDiagnosticsReport {
        ExitDiagnosticsReport(
            exit: ExitIPInfo(ip: ip, country: "Japan", city: "Tokyo", organization: "Example ISP"),
            resolvers: [],
            dns: DNSLeakAssessment(status: .indeterminate, detail: "未取得 DNS 解析器结果"),
            checkedAt: Date(timeIntervalSince1970: 100)
        )
    }

    /// 切换后旧 IP 标「切换前」，拿到新出口才撤；「探测不到出口」的提示随之撤下。
    func testSwitchMarksExitStaleUntilFreshResult() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let answers = ExitAnswers([report("203.0.113.8"), report("198.51.100.20")])
        let state = AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            exitDiagnosticsProvider: { _ in try await answers.next() },
            automaticallyInitialize: false
        )
        await state.refreshExitDiagnostics()
        XCTAssertEqual(state.exitDiagnostics?.exit.ip, "203.0.113.8")

        state.scheduleExitRefreshAfterSwitch(to: "LA")
        XCTAssertTrue(state.exitDiagnosticsIsStale)
        await state.refreshExitDiagnostics()
        XCTAssertFalse(state.exitDiagnosticsIsStale)
        XCTAssertEqual(state.exitDiagnostics?.exit.ip, "198.51.100.20")
    }

    /// 探测进行中又被要求刷新（切换节点时上一次还没跑完）：不吞掉，跑完再测一次。
    func testRefreshRequestedWhileProbingIsNotDropped() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ExitGate()
        let tokyo = report("203.0.113.8")
        let losAngeles = report("198.51.100.20")
        let state = AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            exitDiagnosticsProvider: { _ in
                await gate.enter() == 1 ? tokyo : losAngeles
            },
            automaticallyInitialize: false
        )
        let first = Task { await state.refreshExitDiagnostics() }
        try await Task.sleep(for: .milliseconds(100))
        await state.refreshExitDiagnostics()  // 进行中：只记下，不排队等
        await gate.open()
        await first.value
        let calls = await gate.calls
        XCTAssertEqual(calls, 2, "进行中被要求的那次刷新不能丢")
        XCTAssertEqual(state.exitDiagnostics?.exit.ip, "198.51.100.20")
    }
}

private actor ExitAnswers {
    private var queue: [ExitDiagnosticsReport]
    init(_ queue: [ExitDiagnosticsReport]) { self.queue = queue }
    func next() throws -> ExitDiagnosticsReport {
        guard !queue.isEmpty else { throw URLError(.cannotConnectToHost) }
        return queue.removeFirst()
    }
}

/// 第一次调用卡住直到放行，之后直接通过。
private actor ExitGate {
    private(set) var calls = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func enter() async -> Int {
        calls += 1
        let call = calls
        if call == 1, !isOpen {
            await withCheckedContinuation { waiter = $0 }
        }
        return call
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// 多个网络位置的 `networksetup` 模拟（App 测试用）：读写只作用于当前位置。
private final class AppLocationSimulator: @unchecked Sendable {
    private let lock = NSLock()
    private let locations: [NetworkLocation]
    private var current: String
    private var services: [String: [String]]
    private var dnsState: [String: [String: [String]]] = [:]
    private var proxies: [String: [String: [String: (enabled: Bool, server: String, port: Int)]]] = [:]
    private var listingDelay: Duration?

    init(locations: [NetworkLocation], current: String, services: [String: [String]]) {
        self.locations = locations
        self.current = current
        self.services = services
    }

    func switchTo(_ id: String) { lock.withLock { current = id } }
    func setDNS(_ location: String, _ service: String, _ servers: [String]) { lock.withLock { dnsState[location, default: [:]][service] = servers } }
    func dns(_ location: String, _ service: String) -> [String] { lock.withLock { dnsState[location]?[service] ?? [] } }
    func proxyOnUs(_ location: String, _ service: String) -> Bool {
        lock.withLock { proxies[location]?[service]?["http"]?.enabled == true }
    }
    func delayListing(by delay: Duration?) { lock.withLock { listingDelay = delay } }

    var provider: NetworkLocationsProvider {
        { [self] in
            lock.withLock {
                NetworkLocationsSnapshot(current: locations.first { $0.id == current }, locations: locations, services: [])
            }
        }
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        if arguments.first == "-listallnetworkservices", let delay = lock.withLock({ listingDelay }) {
            try await Task.sleep(for: delay)
        }
        return lock.withLock { handle(arguments) }
    }

    private func handle(_ arguments: [String]) -> ProcessResult {
        func ok(_ stdout: String = "") -> ProcessResult { ProcessResult(exitCode: 0, stdout: stdout, stderr: "") }
        let list = services[current] ?? []
        let service = arguments.count > 1 ? arguments[1] : ""
        func endpoint(_ key: String) -> String {
            let value = proxies[current]?[service]?[key] ?? (false, "", 0)
            return "Enabled: \(value.enabled ? "Yes" : "No")\nServer: \(value.server)\nPort: \(value.port)\n"
        }
        func set(_ key: String, enabled: Bool? = nil, server: String? = nil, port: Int? = nil) {
            var value = proxies[current]?[service]?[key] ?? (false, "", 0)
            if let enabled { value.enabled = enabled }
            if let server { value.server = server; value.enabled = true }
            if let port { value.port = port }
            proxies[current, default: [:]][service, default: [:]][key] = value
        }
        switch arguments.first {
        case "-listallnetworkservices":
            return ok((["An asterisk (*) denotes that a network service is disabled."] + list).joined(separator: "\n"))
        case _ where !list.contains(service):
            return ProcessResult(exitCode: 8, stdout: "** Error: Unable to find item in network database.", stderr: "")
        case "-getdnsservers":
            let servers = dnsState[current]?[service] ?? []
            return ok(servers.isEmpty ? "There aren't any DNS Servers set on \(service).\n" : servers.joined(separator: "\n"))
        case "-setdnsservers":
            let values = Array(arguments.dropFirst(2))
            dnsState[current, default: [:]][service] = values == ["Empty"] ? [] : values
        case "-getwebproxy": return ok(endpoint("http"))
        case "-getsecurewebproxy": return ok(endpoint("https"))
        case "-getsocksfirewallproxy": return ok(endpoint("socks"))
        case "-getproxybypassdomains": return ok("There aren't any bypass domains set on \(service).\n")
        case "-setwebproxy": set("http", server: arguments[2], port: Int(arguments[3]))
        case "-setsecurewebproxy": set("https", server: arguments[2], port: Int(arguments[3]))
        case "-setsocksfirewallproxy": set("socks", server: arguments[2], port: Int(arguments[3]))
        case "-setwebproxystate": set("http", enabled: arguments[2] == "on")
        case "-setsecurewebproxystate": set("https", enabled: arguments[2] == "on")
        case "-setsocksfirewallproxystate": set("socks", enabled: arguments[2] == "on")
        default: break
        }
        return ok()
    }
}
