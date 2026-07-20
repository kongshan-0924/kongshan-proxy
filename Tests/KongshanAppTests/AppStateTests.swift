import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

@MainActor
final class AppStateTests: XCTestCase {
    func testStartWithoutNodesFailsBeforeSystemProxyMutation() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let calls = CommandCalls()
        let storage = Storage(rootDirectory: root)
        let state = AppState(
            storage: storage,
            subscriptionService: SubscriptionService(storage: storage) { _ in
                HTTPDownload(data: Data(), statusCode: 500)
            },
            systemProxyManager: SystemProxyManager(storage: storage) { arguments, _ in
                await calls.append(arguments)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )

        await state.startSystemProxy()

        XCTAssertEqual(state.status, .failed("至少需要一个代理节点"))
        let commandCalls = await calls.values()
        XCTAssertTrue(commandCalls.isEmpty)
    }

    func testAddingManualNodePersistsAndSelectsFirstNode() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        let state = AppState(
            storage: storage,
            subscriptionService: SubscriptionService(storage: storage) { _ in
                HTTPDownload(data: Data(), statusCode: 500)
            },
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )

        await state.addManual(ManualHysteria2(
            name: "自建 01",
            server: "hy.example.com",
            port: 443,
            password: "secret",
            sni: "hy.example.com",
            skipCertificateVerification: false,
            obfsPassword: nil,
            uploadMbps: 20,
            downloadMbps: 100
        ))

        XCTAssertEqual(state.nodes.map(\.name), ["自建 01"])
        XCTAssertEqual(state.selectedNodeID, state.nodes.first?.id)
        XCTAssertNil(state.errorMessage)
        let persistedData = try await storage.readIfPresent(from: root.appending(path: "manual-nodes.json"))
        let persisted = try XCTUnwrap(persistedData)
        XCTAssertEqual(try JSONDecoder().decode([ProxyNode].self, from: persisted).map(\.name), ["自建 01"])
    }

    func testLoadsAndPersistsRoutingSettingsWhileOffline() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        var initial = RoutingSettings.defaults
        initial.bypassDomains = ["initial.local"]
        try await storage.writeAtomically(
            try JSONEncoder().encode(initial),
            to: root.appending(path: "rules.json")
        )
        let calls = CommandCalls()
        let state = AppState(
            storage: storage,
            subscriptionService: SubscriptionService(storage: storage) { _ in
                HTTPDownload(data: Data(), statusCode: 500)
            },
            systemProxyManager: SystemProxyManager(storage: storage) { arguments, _ in
                await calls.append(arguments)
                return ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
        await state.initialize()
        XCTAssertEqual(state.routingSettings, initial)

        var updated = initial
        updated.blockAds = true
        updated.customRules = [
            CustomRouteRule(order: 0, type: .domainSuffix, value: "example.com", action: .proxy, proxyGroup: "自动选择")
        ]
        await state.applyRoutingSettings(updated)

        XCTAssertEqual(state.routingSettings, updated)
        XCTAssertEqual(state.status, .off)
        XCTAssertNil(state.errorMessage)
        let persisted = try Data(contentsOf: root.appending(path: "rules.json"))
        XCTAssertEqual(try JSONDecoder().decode(RoutingSettings.self, from: persisted), updated)
        let commandCalls = await calls.values()
        XCTAssertTrue(commandCalls.isEmpty)
    }

    func testRunningRoutingUpdateReusesRuntimeAndKeepsSystemProxyEnabled() async throws {
        let fixture = try await makeRunningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(fixture.state.status, .on)

        var updated = RoutingSettings.defaults
        updated.bypassDomains.append("intranet.example")
        updated.customRules = [
            CustomRouteRule(order: 0, type: .processName, value: "backup", action: .proxy, proxyGroup: "手动选择")
        ]
        let startedAt = ContinuousClock.now
        await fixture.state.applyRoutingSettings(updated)
        let elapsed = startedAt.duration(to: .now)
        print("M2 hot restart measured: \(elapsed)")

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.routingSettings, updated)
        XCTAssertEqual(fixture.state.mixedPort, fixture.runtime.mixedPort)
        XCTAssertNil(fixture.state.errorMessage)
        XCTAssertLessThan(elapsed, .seconds(2))
        try await ClashAPIClient(
            controller: URL(string: "http://127.0.0.1:\(fixture.runtime.clashPort)")!,
            secret: fixture.runtime.secret
        ).health()
        let commands = await fixture.network.arguments
        XCTAssertEqual(commands.filter { $0.first == "-setwebproxy" }.count, 1)
        XCTAssertTrue(commands.contains(
            ["-setproxybypassdomains", "Wi-Fi"] + updated.systemProxyBypassEntries
        ))
        XCTAssertEqual(
            try JSONDecoder().decode(
                RoutingSettings.self,
                from: Data(contentsOf: fixture.root.appending(path: "rules.json"))
            ),
            updated
        )
        await fixture.state.stop()
        XCTAssertEqual(fixture.state.status, .off)
    }

    func testCoreHealthFailureRestartsOldConfigurationAndKeepsProxyOn() async throws {
        let fixture = try await makeRunningFixture(healthFailures: [2])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.state.routingSettings
        var updated = original
        updated.bypassDomains = ["new.local"]
        updated.bypassCIDRs = []

        await fixture.state.applyRoutingSettings(updated)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.routingSettings, original)
        XCTAssertTrue(fixture.state.errorMessage?.contains("已恢复旧配置") == true)
        let healthCalls = await fixture.health.callCount
        XCTAssertEqual(healthCalls, 3)
        try await ClashAPIClient(
            controller: URL(string: "http://127.0.0.1:\(fixture.runtime.clashPort)")!,
            secret: fixture.runtime.secret
        ).health()
        let commands = await fixture.network.arguments
        XCTAssertFalse(commands.contains(["-setproxybypassdomains", "Wi-Fi", "new.local"]))
        await fixture.state.stop()
    }

    func testBypassFailureRestartsOldCoreAndKeepsOldRules() async throws {
        let fixture = try await makeRunningFixture(
            failOnceFor: ["-setproxybypassdomains", "Wi-Fi", "new.local"]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.state.routingSettings
        var updated = original
        updated.bypassDomains = ["new.local"]
        updated.bypassCIDRs = []

        await fixture.state.applyRoutingSettings(updated)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.routingSettings, original)
        XCTAssertTrue(fixture.state.errorMessage?.contains("已恢复旧配置") == true)
        let commands = await fixture.network.arguments
        XCTAssertTrue(commands.contains(["-setproxybypassdomains", "Wi-Fi", "new.local"]))
        XCTAssertTrue(commands.contains(
            ["-setproxybypassdomains", "Wi-Fi"] + original.systemProxyBypassEntries
        ))
        let healthCalls = await fixture.health.callCount
        XCTAssertEqual(healthCalls, 3)
        await fixture.state.stop()
    }

    func testFailureToRestoreOldCoreRestoresSystemProxyAndMarksFailed() async throws {
        let fixture = try await makeRunningFixture(healthFailures: [2, 3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var updated = fixture.state.routingSettings
        updated.bypassDomains = ["new.local"]
        updated.bypassCIDRs = []

        await fixture.state.applyRoutingSettings(updated)

        if case .failed = fixture.state.status {
            // Expected terminal state.
        } else {
            XCTFail("Expected failed state, got \(fixture.state.status)")
        }
        XCTAssertNil(fixture.state.mixedPort)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appending(path: "proxy-recovery.json").path))
        let isRunning = await fixture.core.isRunning
        XCTAssertFalse(isRunning)
    }

    private func makeRunningFixture(
        failOnceFor: [String]? = nil,
        healthFailures: Set<Int> = []
    ) async throws -> RunningFixture {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = Storage(rootDirectory: root)
        let ruleSetData = try await compiledRuleSet(in: root)
        let network = AppNetworkSetupRecorder(
            recoveryURL: root.appending(path: "proxy-recovery.json"),
            failOnceFor: failOnceFor
        )
        let runtime = try runtimeParameters()
        let core = SingBoxProcess(binaryURL: singBoxURL)
        let health = HealthGate(failures: healthFailures)
        let state = AppState(
            storage: storage,
            subscriptionService: SubscriptionService(storage: storage) { _ in
                HTTPDownload(data: Data(), statusCode: 500)
            },
            ruleSetService: RuleSetService(
                storage: storage,
                binaryURL: singBoxURL,
                loader: { _ in HTTPDownload(data: ruleSetData, statusCode: 200) }
            ),
            systemProxyManager: SystemProxyManager(storage: storage, runner: network.run(arguments:timeout:)),
            singBoxProcess: core,
            runtimeFactory: { runtime },
            healthVerifier: health.verify(client:),
            automaticallyInitialize: false
        )
        state.nodes = [ProxyNode(
            name: "local-test",
            protocolType: .shadowsocks,
            server: "127.0.0.1",
            port: 9,
            password: "secret",
            method: "aes-128-gcm"
        )]
        state.selectedNodeID = state.nodes[0].id
        await state.startSystemProxy()
        return RunningFixture(
            root: root,
            state: state,
            core: core,
            network: network,
            health: health,
            runtime: runtime
        )
    }

    private func compiledRuleSet(in directory: URL) async throws -> Data {
        let source = directory.appending(path: "source.json")
        let output = directory.appending(path: "compiled.srs")
        try Data(#"{"version":3,"rules":[{"domain_suffix":["example.com"]}]}"#.utf8).write(to: source)
        let result = try await ProcessRunner.run(
            executable: singBoxURL,
            arguments: ["rule-set", "compile", source.path, "-o", output.path],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return try Data(contentsOf: output)
    }

    private func runtimeParameters() throws -> RuntimeParameters {
        let mixed = try RuntimeSecrets.availableHighPort()
        var clash = try RuntimeSecrets.availableHighPort()
        while clash == mixed { clash = try RuntimeSecrets.availableHighPort() }
        return RuntimeParameters(mixedPort: mixed, clashPort: clash, secret: try RuntimeSecrets.secret())
    }

    private var singBoxURL: URL {
        packageRoot.appending(path: "Vendor/sing-box/sing-box")
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kongshan-app-state-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

@MainActor
private struct RunningFixture {
    let root: URL
    let state: AppState
    let core: SingBoxProcess
    let network: AppNetworkSetupRecorder
    let health: HealthGate
    let runtime: RuntimeParameters
}

private actor CommandCalls {
    private var arguments: [[String]] = []

    func append(_ value: [String]) {
        arguments.append(value)
    }

    func values() -> [[String]] {
        arguments
    }
}

private actor AppNetworkSetupRecorder {
    private let recoveryURL: URL
    private var failOnceFor: [String]?
    private(set) var arguments: [[String]] = []

    init(recoveryURL: URL, failOnceFor: [String]? = nil) {
        self.recoveryURL = recoveryURL
        self.failOnceFor = failOnceFor
    }

    func run(arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        self.arguments.append(arguments)
        if failOnceFor == arguments {
            failOnceFor = nil
            return ProcessResult(exitCode: 7, stdout: "", stderr: "simulated")
        }
        return ProcessResult(exitCode: 0, stdout: output(for: arguments), stderr: "")
    }

    private func output(for arguments: [String]) -> String {
        switch arguments.first {
        case "-listallnetworkservices":
            "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n"
        case "-getwebproxy", "-getsecurewebproxy", "-getsocksfirewallproxy":
            "Enabled: No\nServer: \nPort: 0\nAuthenticated Proxy Enabled: 0\n"
        case "-getproxybypassdomains":
            "localhost\n*.local\n"
        default:
            ""
        }
    }
}

private actor HealthGate {
    private let failures: Set<Int>
    private(set) var callCount = 0

    init(failures: Set<Int>) {
        self.failures = failures
    }

    func verify(client: ClashAPIClient) async throws {
        callCount += 1
        if failures.contains(callCount) { throw HealthError.simulated }
        var lastError: Error?
        for attempt in 0..<30 {
            do {
                try await client.health()
                return
            } catch {
                lastError = error
                if attempt < 29 { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        throw lastError ?? HealthError.simulated
    }

    private enum HealthError: Error {
        case simulated
    }
}
