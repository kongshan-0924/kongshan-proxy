import Foundation
import XCTest
@testable import KongshanCore

final class SystemProxyManagerTests: XCTestCase {
    func testEnabledServicesSkipsHeaderAndDisabledEntries() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *USB 10/100/1000 LAN
        Thunderbolt Bridge
        """

        XCTAssertEqual(
            SystemProxyCommands.enabledServices(from: output),
            ["Wi-Fi", "Thunderbolt Bridge"]
        )
        XCTAssertEqual(
            SystemProxyCommands.allServices(from: output),
            ["Wi-Fi", "USB 10/100/1000 LAN", "Thunderbolt Bridge"]
        )
    }

    func testParsesProxyStateAndBuildsExactRestoreCommands() throws {
        let http = try SystemProxyCommands.proxyState(from: """
        Enabled: Yes
        Server: old-http.local
        Port: 8080
        Authenticated Proxy Enabled: 0
        """)
        let https = try SystemProxyCommands.proxyState(from: """
        Enabled: No
        Server: old-https.local
        Port: 4443
        Authenticated Proxy Enabled: 0
        """)
        let socks = try SystemProxyCommands.proxyState(from: """
        Enabled: Yes
        Server: old-socks.local
        Port: 1081
        Authenticated Proxy Enabled: 0
        """)
        let snapshot = ProxyRecoverySnapshot(services: [
            NetworkServiceProxySnapshot(
                name: "Wi-Fi",
                http: http,
                https: https,
                socks: socks,
                bypassDomains: ["localhost", "*.local", "10.0.0.0/8"]
            ),
            NetworkServiceProxySnapshot(
                name: "Thunderbolt Bridge",
                http: .init(enabled: false, server: "", port: 0),
                https: .init(enabled: false, server: "", port: 0),
                socks: .init(enabled: false, server: "", port: 0),
                bypassDomains: []
            )
        ])

        XCTAssertEqual(SystemProxyCommands.restore(snapshot: snapshot).map(\.arguments), [
            ["-setwebproxy", "Wi-Fi", "old-http.local", "8080"],
            ["-setwebproxystate", "Wi-Fi", "on"],
            ["-setsecurewebproxy", "Wi-Fi", "old-https.local", "4443"],
            ["-setsecurewebproxystate", "Wi-Fi", "off"],
            ["-setsocksfirewallproxy", "Wi-Fi", "old-socks.local", "1081"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "on"],
            ["-setproxybypassdomains", "Wi-Fi", "localhost", "*.local", "10.0.0.0/8"],
            ["-setwebproxystate", "Thunderbolt Bridge", "off"],
            ["-setsecurewebproxystate", "Thunderbolt Bridge", "off"],
            ["-setsocksfirewallproxystate", "Thunderbolt Bridge", "off"],
            ["-setproxybypassdomains", "Thunderbolt Bridge", "Empty"]
        ])
    }

    /// networksetup 在网络服务列表变动期间会瞬时报
    /// `** Error: Unable to find item in network database.`（exit 8）。
    /// 真机 2026-08-25 07:48（换网 7 分钟后）连报两次「当前配置应用失败，已回滚」，
    /// 且**回滚里的 `-listallnetworkservices` 也一起失败**，系统代理状态一度不确定。
    func testTransientNetworkDatabaseErrorIsRetried() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FlakyNetworkSetup(failures: 2)
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        try await manager.enable(port: 32_123)

        // 两次瞬时失败被吸收，第三次成功；调用方完全看不见这段抖动。
        let listCalls = await runner.calls(matching: "-listallnetworkservices")
        XCTAssertEqual(listCalls, 3)
    }

    /// 重试必须有界。服务若是真被删了，多花约 0.6 秒后照样如实报错——
    /// 不能把「配置错了」伪装成「网络在抖」，那会让用户永远查不到真因。
    func testTransientRetriesAreBoundedAndStillSurfaceTheError() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FlakyNetworkSetup(failures: .max)
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        do {
            try await manager.enable(port: 32_123)
            XCTFail("持续失败时必须抛错")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Unable to find item in network database"),
                "原始错误必须原样透出，实际：\(error.localizedDescription)"
            )
        }
        let listCalls = await runner.calls(matching: "-listallnetworkservices")
        XCTAssertEqual(listCalls, 3, "一次原始调用 + 两次重试，不能无限重试")
    }

    /// 只重试那一种消息。别的失败原样抛出，不许拖慢也不许掩盖。
    func testUnrelatedFailuresAreNotRetried() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FlakyNetworkSetup(failures: .max, stderr: "** Error: some other failure")
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        do {
            try await manager.enable(port: 32_123)
            XCTFail("必须抛错")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("some other failure"))
        }
        let listCalls = await runner.calls(matching: "-listallnetworkservices")
        XCTAssertEqual(listCalls, 1)
    }

    func testEnableWritesRecoverySnapshotBeforeMutatingAndRestoreDeletesIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        let runner = NetworkSetupRecorder(recoveryURL: recoveryURL)
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        try await manager.enable(port: 32_123)

        let snapshotExistedBeforeFirstMutation = await runner.snapshotExistedBeforeFirstMutation
        let mutationArguments = await runner.mutationArguments
        XCTAssertTrue(snapshotExistedBeforeFirstMutation)
        XCTAssertEqual(mutationArguments.prefix(6), [
            ["-setwebproxy", "Wi-Fi", "127.0.0.1", "32123"],
            ["-setwebproxystate", "Wi-Fi", "on"],
            ["-setsecurewebproxy", "Wi-Fi", "127.0.0.1", "32123"],
            ["-setsecurewebproxystate", "Wi-Fi", "on"],
            ["-setsocksfirewallproxy", "Wi-Fi", "127.0.0.1", "32123"],
            ["-setsocksfirewallproxystate", "Wi-Fi", "on"]
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))

        try await manager.restore()

        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
        let restoredArguments = await runner.arguments
        XCTAssertTrue(restoredArguments.contains(["-setwebproxy", "Wi-Fi", "old.local", "8080"]))
        XCTAssertTrue(restoredArguments.contains(["-setwebproxystate", "Wi-Fi", "off"]))
        XCTAssertTrue(restoredArguments.contains(["-setproxybypassdomains", "Wi-Fi", "localhost", "*.local"]))
    }

    func testEnableFailureRollsBackImmediately() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        let runner = NetworkSetupRecorder(
            recoveryURL: recoveryURL,
            failOnceFor: ["-setsecurewebproxystate", "Wi-Fi", "on"]
        )
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        do {
            try await manager.enable(port: 32_123)
            XCTFail("Expected enable failure")
        } catch {
            XCTAssertEqual(error as? SystemProxyError, .commandFailed(exitCode: 7, message: "simulated"))
        }

        let arguments = await runner.arguments
        XCTAssertTrue(arguments.contains(["-setwebproxystate", "Wi-Fi", "off"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    /// 切网络配置后快照里的服务可能此刻不在列表里（Thunderbolt Bridge 拔了、VPN 类虚拟服务随其 App 退出）。
    /// 恢复只处理仍存在的服务，**但已消失的服务不能被静默丢掉**：真机 2026-09-03「Shadowrocket」服务
    /// 就是这样被旧实现跳过并删了快照，之后回到列表时三项代理仍指向已停的中转端口。
    /// 现在它留在快照里作为待还原项，等它回来再复位；期间不向它发任何命令。
    func testRecoverKeepsStaleServicesPendingWithoutTouchingThem() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        // 快照含 Wi-Fi + Thunderbolt Bridge，但 recorder 的 -listallnetworkservices 只返回 Wi-Fi。
        // Wi-Fi 的快照值与 recorder 读回的固定值一致（Enabled: No / old.local / 8080），读回核对能过。
        let snapshot = ProxyRecoverySnapshot(services: [
            NetworkServiceProxySnapshot(
                name: "Wi-Fi",
                http: .init(enabled: false, server: "old.local", port: 8080),
                https: .init(enabled: false, server: "", port: 0),
                socks: .init(enabled: false, server: "", port: 0),
                bypassDomains: []
            ),
            NetworkServiceProxySnapshot(
                name: "Thunderbolt Bridge",
                http: .init(enabled: false, server: "", port: 0),
                https: .init(enabled: false, server: "", port: 0),
                socks: .init(enabled: false, server: "", port: 0),
                bypassDomains: []
            )
        ])
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        try await storage.writeAtomically(JSONEncoder().encode(snapshot), to: recoveryURL)
        let runner = NetworkSetupRecorder(recoveryURL: recoveryURL)
        let manager = SystemProxyManager(storage: storage, runner: runner.run(arguments:timeout:))

        let outcome = try await manager.recoverIfNeeded()

        XCTAssertEqual(outcome.restored, ["Wi-Fi"])
        XCTAssertEqual(outcome.pending, ["Thunderbolt Bridge"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path), "有待还原的服务时快照必须保留")
        let retained = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: Data(contentsOf: recoveryURL))
        XCTAssertEqual(retained.services.map(\.name), ["Thunderbolt Bridge"], "已复位的服务不必再留")
        // 不应对 stale 服务执行任何 networksetup 命令
        let arguments = await runner.arguments
        XCTAssertFalse(arguments.contains { $0.contains("Thunderbolt Bridge") },
                       "不应向已消失的服务发命令")
    }

    /// 单条命令失败不阻塞其它命令，但失败服务必须留在快照里供下次重试。
    func testRecoverKeepsOnlyFailedServiceForRetry() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let snapshot = ProxyRecoverySnapshot(services: [
            NetworkServiceProxySnapshot(
                name: "Wi-Fi",
                http: .init(enabled: false, server: "old.local", port: 8080),
                https: .init(enabled: false, server: "", port: 0),
                socks: .init(enabled: false, server: "", port: 0),
                bypassDomains: []
            )
        ])
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        try await storage.writeAtomically(JSONEncoder().encode(snapshot), to: recoveryURL)
        let runner = NetworkSetupRecorder(
            recoveryURL: recoveryURL,
            failOnceFor: ["-setwebproxystate", "Wi-Fi", "off"]
        )
        let manager = SystemProxyManager(storage: storage, runner: runner.run(arguments:timeout:))

        do {
            try await manager.recoverIfNeeded()
            XCTFail("Expected partial restore failure")
        } catch let error as SystemProxyError {
            // 合并错误：exitCode=-1，message 含「部分网络服务代理恢复失败」
            if case .commandFailed(let code, _) = error {
                XCTAssertEqual(code, -1)
            } else {
                XCTFail("Expected .commandFailed, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
        let retry = try JSONDecoder().decode(
            ProxyRecoverySnapshot.self,
            from: Data(contentsOf: recoveryURL)
        )
        XCTAssertEqual(retry.services.map(\.name), ["Wi-Fi"])

        // 失败条件只触发一次；第二次必须真正恢复并删除快照。
        try await manager.recoverIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    func testRecoverRestoresDisabledButExistingService() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let disabled = NetworkServiceProxySnapshot(
            name: "Disabled LAN",
            http: .init(enabled: false, server: "", port: 0),
            https: .init(enabled: false, server: "", port: 0),
            socks: .init(enabled: false, server: "", port: 0),
            bypassDomains: []
        )
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        try await storage.writeAtomically(
            try JSONEncoder().encode(ProxyRecoverySnapshot(services: [disabled])),
            to: recoveryURL
        )
        let runner = NetworkSetupRecorder(recoveryURL: recoveryURL)
        let manager = SystemProxyManager(storage: storage, runner: runner.run(arguments:timeout:))

        try await manager.recoverIfNeeded()

        let arguments = await runner.arguments
        XCTAssertTrue(arguments.contains(["-setwebproxystate", "Disabled LAN", "off"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    func testUpdateBypassUsesOnlySnapshotServicesAndDoesNotRewriteRecoveryFile() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        let recoveryData = try JSONEncoder().encode(activeSnapshot)
        try await storage.writeAtomically(recoveryData, to: recoveryURL)
        let runner = NetworkSetupRecorder(recoveryURL: recoveryURL)
        let manager = SystemProxyManager(storage: storage, runner: runner.run(arguments:timeout:))

        try await manager.updateBypassDomains(
            to: ["localhost", "*.local", "10.0.0.0/8"],
            rollbackTo: ["localhost"]
        )

        let arguments = await runner.arguments
        XCTAssertEqual(arguments, [
            ["-setproxybypassdomains", "Wi-Fi", "localhost", "*.local", "10.0.0.0/8"],
            ["-setproxybypassdomains", "Thunderbolt Bridge", "localhost", "*.local", "10.0.0.0/8"]
        ])
        XCTAssertEqual(try Data(contentsOf: recoveryURL), recoveryData)
        XCTAssertFalse(arguments.joined().contains { argument in
            ["-setwebproxy", "-setsecurewebproxy", "-setsocksfirewallproxy"].contains(argument)
        })
    }

    func testUpdateBypassFailureRollsEverySnapshotServiceBack() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        let recoveryURL = root.appending(path: "proxy-recovery.json")
        try await storage.writeAtomically(try JSONEncoder().encode(activeSnapshot), to: recoveryURL)
        let runner = NetworkSetupRecorder(
            recoveryURL: recoveryURL,
            failOnceFor: ["-setproxybypassdomains", "Thunderbolt Bridge", "new.local"]
        )
        let manager = SystemProxyManager(storage: storage, runner: runner.run(arguments:timeout:))

        do {
            try await manager.updateBypassDomains(to: ["new.local"], rollbackTo: ["old.local"])
            XCTFail("Expected bypass update failure")
        } catch {
            XCTAssertEqual(error as? SystemProxyError, .commandFailed(exitCode: 7, message: "simulated"))
        }

        let arguments = await runner.arguments
        XCTAssertEqual(arguments, [
            ["-setproxybypassdomains", "Wi-Fi", "new.local"],
            ["-setproxybypassdomains", "Thunderbolt Bridge", "new.local"],
            ["-setproxybypassdomains", "Wi-Fi", "old.local"],
            ["-setproxybypassdomains", "Thunderbolt Bridge", "old.local"]
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    func testUpdateBypassRequiresActiveRecoverySnapshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = NetworkSetupRecorder(recoveryURL: root.appending(path: "proxy-recovery.json"))
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        do {
            try await manager.updateBypassDomains(to: [], rollbackTo: [])
            XCTFail("Expected inactive proxy error")
        } catch {
            XCTAssertEqual(error as? SystemProxyError, .noActiveProxySession)
        }
        let arguments = await runner.arguments
        XCTAssertTrue(arguments.isEmpty)
    }

    private var activeSnapshot: ProxyRecoverySnapshot {
        ProxyRecoverySnapshot(services: [
            NetworkServiceProxySnapshot(
                name: "Wi-Fi",
                http: .init(enabled: false, server: "", port: 0),
                https: .init(enabled: false, server: "", port: 0),
                socks: .init(enabled: false, server: "", port: 0),
                bypassDomains: ["before-wifi.local"]
            ),
            NetworkServiceProxySnapshot(
                name: "Thunderbolt Bridge",
                http: .init(enabled: false, server: "", port: 0),
                https: .init(enabled: false, server: "", port: 0),
                socks: .init(enabled: false, server: "", port: 0),
                bypassDomains: ["before-bridge.local"]
            )
        ])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kongshan-system-proxy-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

private actor NetworkSetupRecorder {
    private let recoveryURL: URL
    private var failOnceFor: [String]?
    private(set) var arguments: [[String]] = []
    private(set) var mutationArguments: [[String]] = []
    private(set) var snapshotExistedBeforeFirstMutation = false

    init(recoveryURL: URL, failOnceFor: [String]? = nil) {
        self.recoveryURL = recoveryURL
        self.failOnceFor = failOnceFor
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        self.arguments.append(arguments)
        if arguments.first?.hasPrefix("-set") == true {
            if mutationArguments.isEmpty {
                snapshotExistedBeforeFirstMutation = FileManager.default.fileExists(atPath: recoveryURL.path)
            }
            mutationArguments.append(arguments)
        }
        if failOnceFor == arguments {
            failOnceFor = nil
            return ProcessResult(exitCode: 7, stdout: "", stderr: "simulated")
        }
        return ProcessResult(exitCode: 0, stdout: output(for: arguments), stderr: "")
    }

    private func output(for arguments: [String]) -> String {
        switch arguments.first {
        case "-listallnetworkservices":
            """
            An asterisk (*) denotes that a network service is disabled.
            Wi-Fi
            *Disabled LAN
            """
        case "-getwebproxy":
            "Enabled: No\nServer: old.local\nPort: 8080\nAuthenticated Proxy Enabled: 0\n"
        case "-getsecurewebproxy":
            "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
        case "-getsocksfirewallproxy":
            "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
        case "-getproxybypassdomains":
            "localhost\n*.local\n"
        default:
            ""
        }
    }
}

/// 前 `failures` 次调用返回指定失败，之后一切正常。
private actor FlakyNetworkSetup {
    private var remainingFailures: Int
    private let stderr: String
    private var seen: [[String]] = []

    init(failures: Int, stderr: String = "** Error: Unable to find item in network database.") {
        self.remainingFailures = failures
        self.stderr = stderr
    }

    func calls(matching argument: String) -> Int {
        seen.filter { $0.first == argument }.count
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        seen.append(arguments)
        guard remainingFailures > 0 else {
            return ProcessResult(exitCode: 0, stdout: output(for: arguments), stderr: "")
        }
        remainingFailures -= 1
        return ProcessResult(exitCode: 8, stdout: "", stderr: stderr)
    }

    private func output(for arguments: [String]) -> String {
        switch arguments.first {
        case "-listallnetworkservices": "Wi-Fi"
        case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
            "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
        default: ""
        }
    }
}
