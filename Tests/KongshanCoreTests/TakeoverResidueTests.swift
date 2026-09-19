import Foundation
import XCTest
@testable import KongshanCore

/// 真机 2026-09-03：停止系统代理时「Shadowrocket」网络服务不在列表里，旧实现静默跳过并删掉快照；
/// 该服务随后回到列表，三项代理仍指向已停的 127.0.0.1:36815——用户关了代理，所有直连请求
/// 仍被送进空端口（Codex 全 404），设置页却显示代理已关。这组测试锁定三层防线：
/// 1. 快照里此刻不在列表的服务保留为待还原，服务回来时自动复位，期间不拒绝再次接管；
/// 2. 写回后读回核对，networksetup 返回 0 但设置没落下去也算失败、快照保留；
/// 3. 不依赖快照的残留清扫，按"设置里指向谁"兜底，且只对接管过的安装生效。
final class TakeoverResidueTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-residue-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func onUs(_ port: Int = 36815) -> ProxyEndpointState {
        ProxyEndpointState(enabled: true, server: "127.0.0.1", port: port)
    }

    private let off = ProxyEndpointState(enabled: false, server: "", port: 0)

    // MARK: - 系统代理：待还原保留

    func testProxyRestoreKeepsAbsentServicePendingAndRestoresItWhenItReappears() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = ProxySettingsSimulator(services: ["Wi-Fi", "Shadowrocket"])
        let manager = SystemProxyManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        try await manager.enable(port: 36815)
        var shadowrocket = await sim.state(of: "Shadowrocket")
        XCTAssertTrue(shadowrocket.http.enabled)

        // Shadowrocket 退出，它的网络服务从列表消失；此时停止代理。
        await sim.setServices(["Wi-Fi"])
        let outcome = try await manager.restore()
        XCTAssertEqual(outcome.restored, ["Wi-Fi"])
        XCTAssertEqual(outcome.pending, ["Shadowrocket"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.recoveryURL.path), "有待还原的服务时快照必须保留")
        let retained = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: Data(contentsOf: manager.recoveryURL))
        XCTAssertEqual(retained.services.map(\.name), ["Shadowrocket"])
        let wifi = await sim.state(of: "Wi-Fi")
        XCTAssertFalse(wifi.http.enabled)
        shadowrocket = await sim.state(of: "Shadowrocket")
        XCTAssertTrue(shadowrocket.http.enabled, "服务不在列表时改不了它，残留仍在——所以快照必须留着")

        // 服务回到列表：下一次恢复把它复位，快照删除。
        await sim.setServices(["Wi-Fi", "Shadowrocket"])
        let second = try await manager.recoverIfNeeded()
        XCTAssertEqual(second.restored, ["Shadowrocket"])
        XCTAssertEqual(second.pending, [])
        shadowrocket = await sim.state(of: "Shadowrocket")
        XCTAssertFalse(shadowrocket.http.enabled)
        XCTAssertFalse(shadowrocket.https.enabled)
        XCTAssertFalse(shadowrocket.socks.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
    }

    func testProxyEnableCarriesPendingServicesInsteadOfRefusing() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = ProxySettingsSimulator(services: ["Wi-Fi", "Shadowrocket"])
        let manager = SystemProxyManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        try await manager.enable(port: 36815)
        await sim.setServices(["Wi-Fi"])
        _ = try await manager.restore()

        // 待还原项不能让用户永远开不了代理；并入本次快照，服务回来时照样复位。
        try await manager.enable(port: 36815)
        let snapshot = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: Data(contentsOf: manager.recoveryURL))
        XCTAssertEqual(Set(snapshot.services.map(\.name)), ["Wi-Fi", "Shadowrocket"])
        let carried = try XCTUnwrap(snapshot.services.first { $0.name == "Shadowrocket" })
        XCTAssertFalse(carried.http.enabled, "带进来的是接管前的原始状态，不是接管中的状态")

        await sim.setServices(["Wi-Fi", "Shadowrocket"])
        let outcome = try await manager.restore()
        XCTAssertEqual(Set(outcome.restored), ["Wi-Fi", "Shadowrocket"])
        XCTAssertEqual(outcome.pending, [])
        let shadowrocket = await sim.state(of: "Shadowrocket")
        XCTAssertFalse(shadowrocket.http.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
    }

    // MARK: - 系统代理：读回核对

    func testProxyRestoreReadsBackAndKeepsSnapshotWhenSettingDidNotStick() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = ProxySettingsSimulator(services: ["Wi-Fi"])
        let manager = SystemProxyManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        try await manager.enable(port: 36815)
        // networksetup 返回 0，但设置不落地。
        await sim.setStuck(["Wi-Fi"])
        do {
            _ = try await manager.restore()
            XCTFail("读回不一致必须报错")
        } catch let error as SystemProxyError {
            guard case let .commandFailed(_, message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Wi-Fi：还原后读回仍不一致"), message)
            XCTAssertTrue(message.contains("HTTP 应为关，实际开"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.recoveryURL.path), "没还原成功就不能删快照")

        // 有快照、服务在列表里、还原不了——这才是真失败：拒绝启用，错误指名服务。
        do {
            try await manager.enable(port: 36815)
            XCTFail("还原失败时不能带着坏快照继续接管")
        } catch let error as SystemProxyError {
            guard case let .commandFailed(_, message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Wi-Fi"), message)
        }

        // 设置能落地了：恢复成功，快照删除。
        await sim.setStuck([])
        let outcome = try await manager.recoverIfNeeded()
        XCTAssertEqual(outcome.restored, ["Wi-Fi"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
    }

    // MARK: - 系统代理：残留清扫

    func testProxySweepDisablesOnlyEndpointsPointingAtOurPort() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1".utf8).write(to: root.appending(path: "proxy-takeover.marker"))
        let sim = ProxySettingsSimulator(services: ["Wi-Fi", "Shadowrocket", "Ethernet"])
        let corp = ProxyEndpointState(enabled: true, server: "proxy.corp.example", port: 8080)
        await sim.set("Wi-Fi", http: onUs(), https: corp, socks: off)
        await sim.set("Shadowrocket", http: onUs(), https: onUs(), socks: onUs())
        await sim.set("Ethernet", http: off, https: off, socks: ProxyEndpointState(enabled: true, server: "127.0.0.1", port: 1080))
        let manager = SystemProxyManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        let cleared = try await manager.sweepResidue(port: 36815)

        XCTAssertEqual(cleared, ["Wi-Fi", "Shadowrocket"])
        let wifi = await sim.state(of: "Wi-Fi")
        XCTAssertFalse(wifi.http.enabled)
        XCTAssertEqual(wifi.https, corp, "指向别处的端点（企业代理）不能动")
        let shadowrocket = await sim.state(of: "Shadowrocket")
        XCTAssertFalse(shadowrocket.http.enabled || shadowrocket.https.enabled || shadowrocket.socks.enabled)
        let ethernet = await sim.state(of: "Ethernet")
        XCTAssertTrue(ethernet.socks.enabled, "同是 127.0.0.1 但不是我们的端口（别的代理软件）不能动")
        let mutations = await sim.mutations
        XCTAssertFalse(mutations.contains { $0.contains("Ethernet") })
        XCTAssertFalse(mutations.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))

        let again = try await manager.sweepResidue(port: 36815)
        XCTAssertEqual(again, [], "清扫必须幂等")
    }

    func testProxySweepIsNoOpUntilThisInstallHasTakenOverOnce() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = ProxySettingsSimulator(services: ["Wi-Fi"])
        await sim.set("Wi-Fi", http: onUs(), https: off, socks: off)
        let manager = SystemProxyManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        // 没有"曾接管"标记：不碰 networksetup——测试夹具、从未开过系统代理的用户。
        let cleared = try await manager.sweepResidue(port: 36815)
        XCTAssertEqual(cleared, [])
        let calls = await sim.calls
        XCTAssertTrue(calls.isEmpty, "无标记时连 -listallnetworkservices 都不该跑：\(calls)")

        // 接管过一次之后标记落盘（只写不删），清扫才生效。
        try await manager.enable(port: 36815)
        _ = try await manager.restore()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "proxy-takeover.marker").path))
        await sim.set("Wi-Fi", http: onUs(), https: off, socks: off)
        let afterTakeover = try await manager.sweepResidue(port: 36815)
        XCTAssertEqual(afterTakeover, ["Wi-Fi"])
    }

    // MARK: - 系统 DNS：同一套防线

    func testDNSRestoreKeepsAbsentServicePendingAndRestoresItWhenItReappears() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = DNSSettingsSimulator(services: ["Wi-Fi", "Shadowrocket"], dns: ["Wi-Fi": ["8.8.8.8"]])
        let manager = SystemDNSManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        try await manager.enable(server: "172.19.0.1")
        await sim.setServices(["Wi-Fi"])
        let outcome = try await manager.restore()
        XCTAssertEqual(outcome.restored, ["Wi-Fi"])
        XCTAssertEqual(outcome.pending, ["Shadowrocket"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
        var wifi = await sim.servers(of: "Wi-Fi")
        XCTAssertEqual(wifi, ["8.8.8.8"])
        var shadowrocket = await sim.servers(of: "Shadowrocket")
        XCTAssertEqual(shadowrocket, ["172.19.0.1"], "服务不在列表时改不了它，残留仍在")

        // 待还原项不阻止再次接管；服务回来后复位。
        try await manager.enable(server: "172.19.0.1")
        await sim.setServices(["Wi-Fi", "Shadowrocket"])
        let second = try await manager.restore()
        XCTAssertEqual(Set(second.restored), ["Wi-Fi", "Shadowrocket"])
        wifi = await sim.servers(of: "Wi-Fi")
        XCTAssertEqual(wifi, ["8.8.8.8"])
        shadowrocket = await sim.servers(of: "Shadowrocket")
        XCTAssertEqual(shadowrocket, [], "复位到接管前的原始状态（DHCP）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
    }

    func testDNSRestoreReadsBackAndKeepsSnapshotWhenSettingDidNotStick() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = DNSSettingsSimulator(services: ["Wi-Fi"], dns: ["Wi-Fi": ["8.8.8.8"]])
        let manager = SystemDNSManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        try await manager.enable(server: "172.19.0.1")
        await sim.setStuck(["Wi-Fi"])
        do {
            _ = try await manager.restore()
            XCTFail("读回不一致必须报错")
        } catch let error as SystemDNSError {
            guard case let .commandFailed(_, message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("Wi-Fi：还原后读回仍不一致"), message)
            XCTAssertTrue(message.contains("应为 8.8.8.8，实际 172.19.0.1"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
    }

    func testDNSSweepRemovesOnlyOurServerAndKeepsUserServers() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sim = DNSSettingsSimulator(
            services: ["Wi-Fi", "Ethernet", "iPhone USB"],
            dns: ["Wi-Fi": ["172.19.0.1", "1.1.1.1"], "Ethernet": ["172.19.0.1"], "iPhone USB": ["8.8.8.8"]]
        )
        let manager = SystemDNSManager(storage: Storage(rootDirectory: root), runner: sim.run(arguments:timeout:))

        // 无标记：不碰 networksetup。
        let before = try await manager.sweepResidue(server: "172.19.0.1")
        XCTAssertEqual(before, [])
        let callsBefore = await sim.calls
        XCTAssertTrue(callsBefore.isEmpty)

        try Data("1".utf8).write(to: root.appending(path: "dns-takeover.marker"))
        let cleared = try await manager.sweepResidue(server: "172.19.0.1")
        XCTAssertEqual(cleared, ["Wi-Fi", "Ethernet"])
        let wifi = await sim.servers(of: "Wi-Fi")
        XCTAssertEqual(wifi, ["1.1.1.1"], "用户自己加的 DNS 保留")
        let ethernet = await sim.servers(of: "Ethernet")
        XCTAssertEqual(ethernet, [], "只有劫持地址时清空回 DHCP")
        let usb = await sim.servers(of: "iPhone USB")
        XCTAssertEqual(usb, ["8.8.8.8"])
        let mutations = await sim.mutations
        XCTAssertEqual(mutations, [
            ["-setdnsservers", "Wi-Fi", "1.1.1.1"],
            ["-setdnsservers", "Ethernet", "Empty"]
        ])
    }
}

// MARK: - 有状态的 networksetup 仿真

/// 按真实 `networksetup` 语义维护每个服务的代理状态：`-setwebproxy` 设地址并打开，
/// `-set*state on|off` 只切开关。`stuck` 里的服务接受命令（返回 0）但状态不变——
/// 模拟"命令成功、设置没落地"，用来验证读回核对。
private actor ProxySettingsSimulator {
    struct ServiceState: Equatable {
        var http: ProxyEndpointState
        var https: ProxyEndpointState
        var socks: ProxyEndpointState
        var bypass: [String]

        static let off = ServiceState(
            http: ProxyEndpointState(enabled: false, server: "", port: 0),
            https: ProxyEndpointState(enabled: false, server: "", port: 0),
            socks: ProxyEndpointState(enabled: false, server: "", port: 0),
            bypass: []
        )
    }

    private var services: [String]
    private var states: [String: ServiceState] = [:]
    private var stuck: Set<String> = []
    private(set) var calls: [[String]] = []
    private(set) var mutations: [[String]] = []

    init(services: [String]) {
        self.services = services
    }

    func setServices(_ services: [String]) { self.services = services }
    func setStuck(_ stuck: Set<String>) { self.stuck = stuck }
    func set(_ service: String, http: ProxyEndpointState, https: ProxyEndpointState, socks: ProxyEndpointState) {
        states[service] = ServiceState(http: http, https: https, socks: socks, bypass: states[service]?.bypass ?? [])
    }
    func state(of service: String) -> ServiceState { states[service] ?? .off }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        calls.append(arguments)
        guard let operation = arguments.first else {
            return ProcessResult(exitCode: 1, stdout: "", stderr: "missing operation")
        }
        if operation.hasPrefix("-set") { mutations.append(arguments) }
        let service = arguments.count > 1 ? arguments[1] : ""
        var state = states[service] ?? .off
        func ok(_ stdout: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: stdout, stderr: "") }
        func render(_ endpoint: ProxyEndpointState) -> String {
            "Enabled: \(endpoint.enabled ? "Yes" : "No")\nServer: \(endpoint.server)\nPort: \(endpoint.port)\nAuthenticated Proxy Enabled: 0\n"
        }

        switch operation {
        case "-listallnetworkservices":
            return ok((["An asterisk (*) denotes that a network service is disabled."] + services).joined(separator: "\n"))
        case "-getwebproxy": return ok(render(state.http))
        case "-getsecurewebproxy": return ok(render(state.https))
        case "-getsocksfirewallproxy": return ok(render(state.socks))
        case "-getproxybypassdomains":
            return ok(state.bypass.isEmpty ? "There aren't any bypass domains set on \(service).\n" : state.bypass.joined(separator: "\n"))
        case "-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy":
            guard !stuck.contains(service), arguments.count >= 4 else { return ok("") }
            let endpoint = ProxyEndpointState(enabled: true, server: arguments[2], port: Int(arguments[3]) ?? 0)
            switch operation {
            case "-setwebproxy": state.http = endpoint
            case "-setsecurewebproxy": state.https = endpoint
            default: state.socks = endpoint
            }
        case "-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate":
            guard !stuck.contains(service), arguments.count >= 3 else { return ok("") }
            let enabled = arguments[2] == "on"
            switch operation {
            case "-setwebproxystate": state.http = ProxyEndpointState(enabled: enabled, server: state.http.server, port: state.http.port)
            case "-setsecurewebproxystate": state.https = ProxyEndpointState(enabled: enabled, server: state.https.server, port: state.https.port)
            default: state.socks = ProxyEndpointState(enabled: enabled, server: state.socks.server, port: state.socks.port)
            }
        case "-setproxybypassdomains":
            guard !stuck.contains(service) else { return ok("") }
            let values = Array(arguments.dropFirst(2))
            state.bypass = values == ["Empty"] ? [] : values
        default:
            return ok("")
        }
        states[service] = state
        return ok("")
    }
}

private actor DNSSettingsSimulator {
    private var services: [String]
    private var dns: [String: [String]]
    private var stuck: Set<String> = []
    private(set) var calls: [[String]] = []
    private(set) var mutations: [[String]] = []

    init(services: [String], dns: [String: [String]]) {
        self.services = services
        self.dns = dns
    }

    func setServices(_ services: [String]) { self.services = services }
    func setStuck(_ stuck: Set<String>) { self.stuck = stuck }
    func servers(of service: String) -> [String] { dns[service] ?? [] }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        calls.append(arguments)
        let service = arguments.count > 1 ? arguments[1] : ""
        switch arguments.first {
        case "-listallnetworkservices":
            return ProcessResult(
                exitCode: 0,
                stdout: (["An asterisk (*) denotes that a network service is disabled."] + services).joined(separator: "\n"),
                stderr: ""
            )
        case "-getdnsservers":
            let servers = dns[service] ?? []
            return ProcessResult(
                exitCode: 0,
                stdout: servers.isEmpty ? "There aren't any DNS Servers set on \(service).\n" : servers.joined(separator: "\n"),
                stderr: ""
            )
        case "-setdnsservers":
            mutations.append(arguments)
            if !stuck.contains(service) {
                let values = Array(arguments.dropFirst(2))
                dns[service] = values == ["Empty"] ? [] : values
            }
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
}
