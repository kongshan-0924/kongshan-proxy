import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// 真机 2026-09-03：用户关掉系统代理后，「Shadowrocket」网络服务的三项代理仍指向 kongshan 已停的
/// 127.0.0.1:36815——还原时该服务不在列表里被静默跳过，快照也删了；用户所有直连请求被送进空端口
/// （Codex 全 404），设置页却显示代理已关。这组测试锁定 App 层的接线：
/// - 启动 / 换网时对**没在接管**的那类做"快照精确还原 + 不依赖快照的残留清扫"，并记事件；
/// - 回滚路径上的接管还原失败不能再用 `try?` 吞掉。
@MainActor
final class TakeoverResidueWiringTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appStateSource() throws -> String {
        try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/AppState.swift"),
            encoding: .utf8
        )
    }

    /// 从函数签名到它的收尾 `    }`（四空格缩进）之间的文本。
    private func body(of signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), "找不到 \(signature)")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-residue-wiring-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// `PersistedSettings` 是 AppState 的私有类型，这里按它的必填字段手写：`testURL` 非可选。
    private func writeSettings(relayPort: Int, to root: URL) throws {
        let json = "{\"testURL\":\"https://www.gstatic.com/generate_204\",\"proxyRelayPort\":\(relayPort)}"
        try Data(json.utf8).write(to: root.appending(path: "settings.json"))
    }

    private func makeState(root: URL, simulator: AppNetworkSetupSimulator) -> AppState {
        let storage = Storage(rootDirectory: root)
        return AppState(
            storage: storage,
            subscriptionService: SubscriptionService(storage: storage) { _ in
                HTTPDownload(data: Data(), statusCode: 500)
            },
            systemProxyManager: SystemProxyManager(storage: storage, runner: simulator.run(arguments:timeout:)),
            systemDNSManager: SystemDNSManager(storage: storage, runner: simulator.run(arguments:timeout:)),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
    }

    // MARK: - 行为

    func testLaunchSweepsProxyAndDNSResidueAndRecordsEvents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // 这个安装接管过（标记只写不删），上次的中转端口是 36815。
        try Data("1".utf8).write(to: root.appending(path: "proxy-takeover.marker"))
        try Data("1".utf8).write(to: root.appending(path: "dns-takeover.marker"))
        try writeSettings(relayPort: 36815, to: root)
        let hijack = TunSettings.defaults.dnsServerAddress
        let simulator = AppNetworkSetupSimulator(proxyPort: 36815, dns: [hijack, "1.1.1.1"])
        let state = makeState(root: root, simulator: simulator)

        await state.initialize()

        XCTAssertNil(state.errorMessage, "启动不应失败")
        let calls = await simulator.calls
        XCTAssertTrue(calls.contains(["-setwebproxystate", "Wi-Fi", "off"]), "\(calls)")
        XCTAssertTrue(calls.contains(["-setsecurewebproxystate", "Wi-Fi", "off"]))
        XCTAssertTrue(calls.contains(["-setsocksfirewallproxystate", "Wi-Fi", "off"]))
        XCTAssertTrue(calls.contains(["-setdnsservers", "Wi-Fi", "1.1.1.1"]), "只摘劫持地址，用户自己的 DNS 保留：\(calls)")
        let titles = state.runtimeEvents.map(\.title)
        XCTAssertTrue(titles.contains("已清理残留的系统代理设置"), "\(titles)")
        XCTAssertTrue(titles.contains("已清理残留的系统 DNS 设置"), "\(titles)")
        let detail = state.runtimeEvents.first { $0.title == "已清理残留的系统代理设置" }?.detail ?? ""
        XCTAssertTrue(detail.contains("Wi-Fi") && detail.contains("36815"), detail)
        XCTAssertEqual(state.warnings, [])
    }

    func testLaunchWithoutTakeoverHistoryTouchesNothing() async throws {
        // 从未接管过的安装（无标记）：即便设置里有指向本机端口的代理也不动——不是这个安装留下的，
        // 也保证测试夹具 / 从未开过对应模式的用户不会每次启动、换网都去跑 networksetup。
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSettings(relayPort: 36815, to: root)
        let simulator = AppNetworkSetupSimulator(proxyPort: 36815, dns: [TunSettings.defaults.dnsServerAddress])
        let state = makeState(root: root, simulator: simulator)

        await state.initialize()

        let calls = await simulator.calls
        XCTAssertTrue(calls.isEmpty, "无接管历史时不应碰 networksetup：\(calls)")
        XCTAssertTrue(state.runtimeEvents.allSatisfy { !$0.title.contains("残留") })
    }

    func testNetworkChangeWhileOffReconcilesTakeovers() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("1".utf8).write(to: root.appending(path: "proxy-takeover.marker"))
        try writeSettings(relayPort: 36815, to: root)
        let simulator = AppNetworkSetupSimulator(proxyPort: 36815, dns: [])
        // 启动时先不留残留，换网后才出现（VPN 类虚拟服务回到列表）。
        await simulator.setProxyEnabled(false)
        let state = makeState(root: root, simulator: simulator)
        await state.initialize()
        await simulator.setProxyEnabled(true)

        await state.reassertTakeoversAfterNetworkChange()

        let calls = await simulator.calls
        XCTAssertTrue(calls.contains(["-setwebproxystate", "Wi-Fi", "off"]), "未接管时换网也要清残留：\(calls)")
        let event = state.runtimeEvents.first { $0.title == "已清理残留的系统代理设置" }
        XCTAssertTrue(event?.detail?.hasPrefix("网络变化时") == true, event?.detail ?? "无事件")
    }

    // MARK: - 源码守卫

    func testNoRollbackPathSwallowsTakeoverRestoreFailures() throws {
        let source = try appStateSource()
        for forbidden in [
            "try? await systemProxyManager.restore()",
            "try? await systemDNSManager.restore()",
            "try? await sshProxyConfigManager.apply(targets: [], relayPort: nil)"
        ] {
            XCTAssertFalse(source.contains(forbidden), "回滚路径上的接管还原失败不能用 try? 吞掉：\(forbidden)")
        }
    }

    func testLaunchAndNetworkChangeReconcileInactiveTakeovers() throws {
        let source = try appStateSource()
        let initialize = try body(of: "func initialize() async {", in: source)
        XCTAssertTrue(initialize.contains("reconcileInactiveTakeovers(trigger: \"启动\")"), "启动必须清理遗留接管")

        let schedule = try body(of: "private func scheduleTakeoverReassert() {", in: source)
        XCTAssertFalse(schedule.contains("guard status == .on"), "未接管时换网也要调度清理，不能在调度层就拦掉")

        let reassert = try body(of: "func reassertTakeoversAfterNetworkChange(", in: source)
        XCTAssertTrue(
            reassert.contains("guard status == .on else {\n            await reconcileInactiveTakeovers(trigger: \"网络变化\")"),
            "未接管时换网必须走 reconcileInactiveTakeovers"
        )
        XCTAssertTrue(reassert.contains("await reconcileInactiveTakeovers(trigger: \"网络变化\")\n    }") || reassert.hasSuffix("await reconcileInactiveTakeovers(trigger: \"网络变化\")") || reassert.components(separatedBy: "reconcileInactiveTakeovers(trigger: \"网络变化\")").count >= 3,
            "接管中换网也要按类清扫另一类的遗留")
    }
}

/// 一个 Wi-Fi 服务：三项代理指向 127.0.0.1:<proxyPort>，DNS 为给定列表；按真实 networksetup 语义响应。
private actor AppNetworkSetupSimulator {
    private var proxyEnabled = true
    private let proxyPort: Int
    private var dns: [String]
    private(set) var calls: [[String]] = []

    init(proxyPort: Int, dns: [String]) {
        self.proxyPort = proxyPort
        self.dns = dns
    }

    func setProxyEnabled(_ enabled: Bool) { proxyEnabled = enabled }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        calls.append(arguments)
        func ok(_ stdout: String) -> ProcessResult { ProcessResult(exitCode: 0, stdout: stdout, stderr: "") }
        let proxy = "Enabled: \(proxyEnabled ? "Yes" : "No")\nServer: 127.0.0.1\nPort: \(proxyPort)\nAuthenticated Proxy Enabled: 0\n"
        switch arguments.first {
        case "-listallnetworkservices":
            return ok("An asterisk (*) denotes that a network service is disabled.\nWi-Fi")
        case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
            return ok(proxy)
        case "-getproxybypassdomains":
            return ok("There aren't any bypass domains set on Wi-Fi.\n")
        case "-setwebproxystate", "-setsecurewebproxystate", "-setsocksfirewallproxystate":
            if arguments.count >= 3 { proxyEnabled = arguments[2] == "on" }
            return ok("")
        case "-getdnsservers":
            return ok(dns.isEmpty ? "There aren't any DNS Servers set on Wi-Fi.\n" : dns.joined(separator: "\n"))
        case "-setdnsservers":
            let values = Array(arguments.dropFirst(2))
            dns = values == ["Empty"] ? [] : values
            return ok("")
        default:
            return ok("")
        }
    }
}
