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

    func testOldSettingsDefaultToSystemModeAndNewModePersists() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        try await storage.writeAtomically(
            Data(#"{"selectedNodeID":null,"testURL":"http://example.com/generate_204"}"#.utf8),
            to: root.appending(path: "settings.json")
        )
        let privileged = FakePrivilegedLauncher(root: root)
        let state = AppState(
            storage: storage,
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            privilegedLauncher: privileged,
            automaticallyInitialize: false
        )

        await state.initialize()

        XCTAssertEqual(state.preferredMode, .systemProxy)
        XCTAssertNil(state.activeMode)
        XCTAssertEqual(state.tunSettings, .defaults)
        await state.switchMode(to: .tun)
        XCTAssertEqual(state.preferredMode, .tun)
        XCTAssertEqual(state.status, .off)

        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "settings.json")))
                as? [String: Any]
        )
        XCTAssertEqual(persisted["preferredMode"] as? String, "tun")
        XCTAssertEqual((persisted["tunSettings"] as? [String: Any])?["strictRoute"] as? Bool, false)

        let reloaded = AppState(
            storage: storage,
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            privilegedLauncher: privileged,
            automaticallyInitialize: false
        )
        await reloaded.initialize()
        XCTAssertEqual(reloaded.preferredMode, .tun)
        XCTAssertEqual(reloaded.tunSettings, .defaults)
    }

    func testSwitchSystemProxyToTUNFullyStopsOldTakeoverFirst() async throws {
        let fixture = try await makeModeFixture(initialMode: .systemProxy)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(fixture.state.activeMode, .systemProxy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.proxyRecoveryURL.path))

        await fixture.state.switchMode(to: .tun)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.preferredMode, .tun)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.proxyRecoveryURL.path))
        let tunIsActive = await fixture.privileged.isActive()
        let userCoreIsRunning = await fixture.core.isRunning
        XCTAssertTrue(tunIsActive)
        XCTAssertFalse(userCoreIsRunning)
        let configs = await fixture.privileged.startedConfigs()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(configs.last)) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["type"] as? String, "tun")
        let events = await fixture.events.values()
        let violations = await fixture.events.invariantViolations()
        XCTAssertEqual(events, [.systemEnable, .systemRestore, .tunStart])
        XCTAssertTrue(violations.isEmpty)
    }

    func testSwitchTUNToSystemProxyStopsRootBeforeNetworkSetup() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertEqual(fixture.state.activeMode, .tun)
        let initiallyActive = await fixture.privileged.isActive()
        XCTAssertTrue(initiallyActive)

        await fixture.state.switchMode(to: .systemProxy)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.preferredMode, .systemProxy)
        XCTAssertEqual(fixture.state.activeMode, .systemProxy)
        let tunIsActive = await fixture.privileged.isActive()
        let userCoreIsRunning = await fixture.core.isRunning
        XCTAssertFalse(tunIsActive)
        XCTAssertTrue(userCoreIsRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.proxyRecoveryURL.path))
        let events = await fixture.events.values()
        let violations = await fixture.events.invariantViolations()
        XCTAssertEqual(events, [.tunStart, .tunStop, .systemEnable])
        XCTAssertTrue(violations.isEmpty)
        await fixture.state.stop()
    }

    func testNewModeFailureLeavesBothTakeoversOff() async throws {
        let fixture = try await makeModeFixture(
            initialMode: .systemProxy,
            tunStartError: ModeTestError.startFailed
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        await fixture.state.switchMode(to: .tun)

        if case .failed = fixture.state.status {
            // Expected terminal state.
        } else {
            XCTFail("Expected failed state, got \(fixture.state.status)")
        }
        XCTAssertEqual(fixture.state.preferredMode, .tun)
        XCTAssertNil(fixture.state.activeMode)
        let tunIsActive = await fixture.privileged.isActive()
        let userCoreIsRunning = await fixture.core.isRunning
        XCTAssertFalse(tunIsActive)
        XCTAssertFalse(userCoreIsRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.proxyRecoveryURL.path))
        let events = await fixture.events.values()
        XCTAssertEqual(events, [.systemEnable, .systemRestore, .tunStart])
    }

    func testInitializeAndTerminationSurfaceTUNRecoveryFailures() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        let recoveryFailure = FakePrivilegedLauncher(
            root: root,
            recoverError: ModeTestError.recoveryFailed
        )
        let failedInitialization = AppState(
            storage: storage,
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            privilegedLauncher: recoveryFailure,
            automaticallyInitialize: false
        )

        await failedInitialization.initialize()

        XCTAssertFalse(failedInitialization.isReady)
        if case .failed = failedInitialization.status {
            // Expected recovery failure.
        } else {
            XCTFail("Expected failed initialization")
        }

        let fixture = try await makeModeFixture(
            initialMode: .tun,
            tunStopError: ModeTestError.stopFailed
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canTerminate = await fixture.state.prepareForTermination()
        XCTAssertFalse(canTerminate)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        let tunIsActive = await fixture.privileged.isActive()
        XCTAssertTrue(tunIsActive)
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

    private func makeModeFixture(
        initialMode: ProxyMode,
        tunStartError: Error? = nil,
        tunStopError: Error? = nil
    ) async throws -> ModeFixture {
        let root = temporaryDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = Storage(rootDirectory: root)
        let ruleSetData = try await compiledRuleSet(in: root)
        let events = TakeoverEvents()
        let markerURL = root.appending(path: "fake-tun-active")
        let proxyRecoveryURL = root.appending(path: "proxy-recovery.json")
        let network = AppNetworkSetupRecorder(
            recoveryURL: proxyRecoveryURL,
            tunMarkerURL: markerURL,
            takeoverEvents: events
        )
        let runtime = try runtimeParameters()
        let core = SingBoxProcess(binaryURL: singBoxURL)
        let privileged = FakePrivilegedLauncher(
            root: root,
            markerURL: markerURL,
            proxyRecoveryURL: proxyRecoveryURL,
            events: events,
            startError: tunStartError,
            stopError: tunStopError
        )
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
            privilegedLauncher: privileged,
            runtimeFactory: { runtime },
            healthVerifier: { _ in },
            automaticallyInitialize: false
        )
        state.nodes = [ProxyNode(
            name: "mode-test",
            protocolType: .shadowsocks,
            server: "127.0.0.1",
            port: 9,
            password: "secret",
            method: "aes-128-gcm"
        )]
        state.selectedNodeID = state.nodes[0].id
        if initialMode != .systemProxy {
            await state.switchMode(to: initialMode)
        }
        await state.startSystemProxy()
        XCTAssertEqual(state.status, .on)
        return ModeFixture(
            root: root,
            state: state,
            core: core,
            privileged: privileged,
            events: events,
            proxyRecoveryURL: proxyRecoveryURL
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

@MainActor
private struct ModeFixture {
    let root: URL
    let state: AppState
    let core: SingBoxProcess
    let privileged: FakePrivilegedLauncher
    let events: TakeoverEvents
    let proxyRecoveryURL: URL
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
    private let tunMarkerURL: URL?
    private let takeoverEvents: TakeoverEvents?
    private var failOnceFor: [String]?
    private var recordedEnable = false
    private var recordedRestore = false
    private(set) var arguments: [[String]] = []

    init(
        recoveryURL: URL,
        failOnceFor: [String]? = nil,
        tunMarkerURL: URL? = nil,
        takeoverEvents: TakeoverEvents? = nil
    ) {
        self.recoveryURL = recoveryURL
        self.failOnceFor = failOnceFor
        self.tunMarkerURL = tunMarkerURL
        self.takeoverEvents = takeoverEvents
    }

    func run(arguments: [String], timeout: TimeInterval) async -> ProcessResult {
        self.arguments.append(arguments)
        if arguments.first == "-setwebproxy", !recordedEnable {
            recordedEnable = true
            if let tunMarkerURL, FileManager.default.fileExists(atPath: tunMarkerURL.path) {
                await takeoverEvents?.recordViolation("system proxy enabled while TUN marker exists")
            }
            await takeoverEvents?.append(.systemEnable)
        }
        if arguments.starts(with: ["-setwebproxystate", "Wi-Fi", "off"]), !recordedRestore {
            recordedRestore = true
            await takeoverEvents?.append(.systemRestore)
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

private enum TakeoverEvent: Equatable, Sendable {
    case systemEnable
    case systemRestore
    case tunStart
    case tunStop
}

private actor TakeoverEvents {
    private var events: [TakeoverEvent] = []
    private var violations: [String] = []

    func append(_ event: TakeoverEvent) { events.append(event) }
    func recordViolation(_ message: String) { violations.append(message) }
    func values() -> [TakeoverEvent] { events }
    func invariantViolations() -> [String] { violations }
}

private actor FakePrivilegedLauncher: PrivilegedLaunching {
    private let markerURL: URL
    private let proxyRecoveryURL: URL
    private let events: TakeoverEvents?
    private let startError: Error?
    private let stopError: Error?
    private let recoverError: Error?
    private var active = false
    private var configs: [Data] = []

    init(
        root: URL,
        markerURL: URL? = nil,
        proxyRecoveryURL: URL? = nil,
        events: TakeoverEvents? = nil,
        startError: Error? = nil,
        stopError: Error? = nil,
        recoverError: Error? = nil
    ) {
        self.markerURL = markerURL ?? root.appending(path: "fake-tun-active")
        self.proxyRecoveryURL = proxyRecoveryURL ?? root.appending(path: "proxy-recovery.json")
        self.events = events
        self.startError = startError
        self.stopError = stopError
        self.recoverError = recoverError
    }

    func start(config: Data) async throws -> PrivilegedProcessRecord {
        await events?.append(.tunStart)
        if FileManager.default.fileExists(atPath: proxyRecoveryURL.path) {
            await events?.recordViolation("TUN started while system proxy recovery exists")
        }
        if let startError { throw startError }
        configs.append(config)
        active = true
        try Data().write(to: markerURL)
        return PrivilegedProcessRecord(
            pid: 4321,
            binaryPath: "/fake/sing-box",
            launchedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func stop() async throws {
        await events?.append(.tunStop)
        if let stopError { throw stopError }
        active = false
        try? FileManager.default.removeItem(at: markerURL)
    }

    func recoverIfNeeded() async throws {
        if let recoverError { throw recoverError }
        active = false
        try? FileManager.default.removeItem(at: markerURL)
    }

    func isActive() -> Bool { active }
    func startedConfigs() -> [Data] { configs }
}

private enum ModeTestError: Error {
    case startFailed
    case stopFailed
    case recoveryFailed
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
