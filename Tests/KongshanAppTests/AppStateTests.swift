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

    func testTUNRoutingUpdateReusesRuntimeAndNeverCallsNetworkSetup() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let initialConfigs = await fixture.privileged.attemptedConfigs()
        let initialConfig = try XCTUnwrap(initialConfigs.last)
        let initialRuntime = try clashRuntime(from: initialConfig)
        let networkCallsBefore = await fixture.network.arguments.count
        var updated = fixture.state.routingSettings
        updated.bypassCIDRs = ["10.20.0.0/16", "192.168.50.0/24"]

        await fixture.state.applyRoutingSettings(updated)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertEqual(fixture.state.routingSettings, updated)
        let configs = await fixture.privileged.attemptedConfigs()
        XCTAssertEqual(configs.count, 2)
        let updatedConfig = try XCTUnwrap(configs.last)
        XCTAssertEqual(try clashRuntime(from: updatedConfig).controller, initialRuntime.controller)
        XCTAssertEqual(try clashRuntime(from: updatedConfig).secret, initialRuntime.secret)
        XCTAssertEqual(
            try tunRouteExclusions(from: updatedConfig),
            ["10.20.0.0/16", "192.168.50.0/24"]
        )
        let networkCallsAfter = await fixture.network.arguments.count
        let events = await fixture.events.values()
        XCTAssertEqual(networkCallsAfter, networkCallsBefore)
        XCTAssertEqual(events, [.tunStart, .tunStop, .tunStart])
    }

    func testTUNRoutingStartFailureRestoresOldRootConfiguration() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun, tunStartFailureCalls: [2])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSettings = fixture.state.routingSettings
        var updated = oldSettings
        updated.bypassCIDRs = ["10.88.0.0/16"]

        await fixture.state.applyRoutingSettings(updated)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertEqual(fixture.state.routingSettings, oldSettings)
        XCTAssertTrue(fixture.state.errorMessage?.contains("已恢复旧 TUN 配置") == true)
        let tunIsActive = await fixture.privileged.isActive()
        let attempts = await fixture.privileged.attemptedConfigs()
        let networkArguments = await fixture.network.arguments
        XCTAssertTrue(tunIsActive)
        XCTAssertEqual(attempts.count, 3)
        guard attempts.count == 3 else { return }
        XCTAssertEqual(attempts[0], attempts[2])
        XCTAssertNotEqual(attempts[0], attempts[1])
        XCTAssertTrue(networkArguments.isEmpty)
    }

    func testTUNRoutingDoubleStartFailureLeavesNoTakeoverOrRuntime() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun, tunStartFailureCalls: [2, 3])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var updated = fixture.state.routingSettings
        updated.bypassCIDRs = ["10.99.0.0/16"]

        await fixture.state.applyRoutingSettings(updated)

        if case .failed = fixture.state.status {
            // Expected terminal failure.
        } else {
            XCTFail("Expected failed state, got \(fixture.state.status)")
        }
        XCTAssertNil(fixture.state.activeMode)
        XCTAssertNil(fixture.state.mixedPort)
        let tunIsActive = await fixture.privileged.isActive()
        let coreIsRunning = await fixture.core.isRunning
        let networkArguments = await fixture.network.arguments
        XCTAssertFalse(tunIsActive)
        XCTAssertFalse(coreIsRunning)
        XCTAssertTrue(networkArguments.isEmpty)
    }

    func testOfflineTUNSettingsPersistWithoutStartingTakeover() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
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
        var settings = TunSettings.defaults
        settings.strictRoute = true

        await state.applyTunSettings(settings)

        XCTAssertEqual(state.tunSettings, settings)
        XCTAssertEqual(state.status, .off)
        let attempts = await privileged.attemptedConfigs()
        XCTAssertTrue(attempts.isEmpty)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "settings.json")))
                as? [String: Any]
        )
        XCTAssertEqual((persisted["tunSettings"] as? [String: Any])?["strictRoute"] as? Bool, true)
    }

    func testActiveTUNStrictRouteUpdateUsesPrivilegedTransaction() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = fixture.state.tunSettings
        settings.strictRoute = true

        await fixture.state.applyTunSettings(settings)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertEqual(fixture.state.tunSettings, settings)
        let attempts = await fixture.privileged.attemptedConfigs()
        let networkArguments = await fixture.network.arguments
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(try tunStrictRoute(from: try XCTUnwrap(attempts.last)), true)
        XCTAssertTrue(networkArguments.isEmpty)
    }

    func testActiveTUNStrictRouteFailureRestoresOldConfiguration() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun, tunStartFailureCalls: [2])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSettings = fixture.state.tunSettings
        var requested = oldSettings
        requested.strictRoute = true

        await fixture.state.applyTunSettings(requested)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertEqual(fixture.state.tunSettings, oldSettings)
        XCTAssertTrue(fixture.state.errorMessage?.contains("已恢复旧 TUN 配置") == true)
        let attempts = await fixture.privileged.attemptedConfigs()
        XCTAssertEqual(attempts.count, 3)
        guard attempts.count == 3 else { return }
        XCTAssertEqual(attempts[0], attempts[2])
        XCTAssertEqual(try tunStrictRoute(from: attempts[1]), true)
    }

    func testOldSettingsDefaultDNSAndOfflineCustomDNSPersists() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        try await storage.writeAtomically(
            Data(#"{"selectedNodeID":null,"testURL":"http://example.com/generate_204"}"#.utf8),
            to: root.appending(path: "settings.json")
        )
        let state = AppState(
            storage: storage,
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            privilegedLauncher: FakePrivilegedLauncher(root: root),
            automaticallyInitialize: false
        )

        await state.initialize()
        XCTAssertEqual(state.dnsSettings, .defaults)

        let custom = customDNSSettings
        await state.applyDNSSettings(custom)

        XCTAssertEqual(state.status, .off)
        XCTAssertEqual(state.dnsSettings, custom)
        XCTAssertNil(state.errorMessage)
        let data = try Data(contentsOf: root.appending(path: "settings.json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let persisted = try XCTUnwrap(object["dnsSettings"] as? [String: Any])
        XCTAssertEqual(persisted["domesticDoH"] as? String, custom.domesticDoH)
        XCTAssertEqual(persisted["remoteDoH"] as? String, custom.remoteDoH)
    }

    func testActiveSystemDNSUpdateRestartsCoreWithoutReenablingProxy() async throws {
        let fixture = try await makeRunningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let networkCallsBefore = await fixture.network.arguments

        await fixture.state.applyDNSSettings(customDNSSettings)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .systemProxy)
        XCTAssertEqual(fixture.state.dnsSettings, customDNSSettings)
        XCTAssertNil(fixture.state.errorMessage)
        let config = try Data(contentsOf: fixture.root.appending(path: "config.json"))
        XCTAssertEqual(try dnsURLs(from: config), customDNSSettings)
        let networkCallsAfter = await fixture.network.arguments
        XCTAssertEqual(
            networkCallsAfter.filter { $0.first == "-setwebproxy" }.count,
            networkCallsBefore.filter { $0.first == "-setwebproxy" }.count
        )
        let healthCalls = await fixture.health.callCount
        XCTAssertEqual(healthCalls, 2)
        await fixture.state.stop()
    }

    func testActiveSystemDNSHealthFailureRestoresOldConfiguration() async throws {
        let fixture = try await makeRunningFixture(healthFailures: [2])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.state.dnsSettings

        await fixture.state.applyDNSSettings(customDNSSettings)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.dnsSettings, original)
        XCTAssertTrue(fixture.state.errorMessage?.contains("已恢复旧配置") == true)
        let healthCalls = await fixture.health.callCount
        XCTAssertEqual(healthCalls, 3)
        try await ClashAPIClient(
            controller: URL(string: "http://127.0.0.1:\(fixture.runtime.clashPort)")!,
            secret: fixture.runtime.secret
        ).health()
        await fixture.state.stop()
    }

    func testActiveTUNDNSUpdateUsesPrivilegedTransaction() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let networkCallsBefore = await fixture.network.arguments.count

        await fixture.state.applyDNSSettings(customDNSSettings)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertEqual(fixture.state.dnsSettings, customDNSSettings)
        XCTAssertNil(fixture.state.errorMessage)
        let attempts = await fixture.privileged.attemptedConfigs()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(try dnsURLs(from: try XCTUnwrap(attempts.last)), customDNSSettings)
        let networkCallsAfter = await fixture.network.arguments.count
        XCTAssertEqual(networkCallsAfter, networkCallsBefore)
    }

    func testActiveTUNDNSFailureRestoresOldConfiguration() async throws {
        let fixture = try await makeModeFixture(initialMode: .tun, tunStartFailureCalls: [2])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.state.dnsSettings

        await fixture.state.applyDNSSettings(customDNSSettings)

        XCTAssertEqual(fixture.state.status, .on)
        XCTAssertEqual(fixture.state.activeMode, .tun)
        XCTAssertEqual(fixture.state.dnsSettings, original)
        XCTAssertTrue(fixture.state.errorMessage?.contains("已恢复旧 TUN 配置") == true)
        let attempts = await fixture.privileged.attemptedConfigs()
        XCTAssertEqual(attempts.count, 3)
        guard attempts.count == 3 else { return }
        XCTAssertEqual(attempts[0], attempts[2])
        XCTAssertEqual(try dnsURLs(from: attempts[1]), customDNSSettings)
    }

    func testDashboardMonitoringKeepsSixtyPointsAndIsIdempotent() async throws {
        let streams = DashboardStreamFixture(sampleCount: 65)
        let fixture = try await makeModeFixture(
            initialMode: .systemProxy,
            clashClientFactory: { controller, secret in
                ClashAPIClient(
                    controller: controller,
                    secret: secret,
                    streamFactory: streams.stream(for:)
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.state.startDashboardMonitoring()
        fixture.state.startDashboardMonitoring()
        try await waitUntil {
            fixture.state.trafficHistory.count == 60 && fixture.state.activeConnectionCount == 2
        }

        XCTAssertEqual(fixture.state.uploadRate, 64)
        XCTAssertEqual(fixture.state.downloadRate, 128)
        XCTAssertEqual(fixture.state.trafficHistory.first?.upload, 5)
        XCTAssertEqual(fixture.state.trafficHistory.last?.download, 128)
        XCTAssertEqual(fixture.state.coreMemory, 4_194_304)
        XCTAssertNotNil(fixture.state.runtimeStartedAt)
        XCTAssertEqual(streams.requestCount(path: "/traffic"), 1)
        XCTAssertEqual(streams.requestCount(path: "/connections"), 1)

        fixture.state.stopDashboardMonitoring()
        try await waitUntil { streams.terminationCount == 2 }
        await fixture.state.stop()
    }

    func testDashboardMonitoringDoesNothingWhileProxyIsOff() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let streams = DashboardStreamFixture(sampleCount: 1)
        let storage = Storage(rootDirectory: root)
        let state = AppState(
            storage: storage,
            systemProxyManager: SystemProxyManager(storage: storage) { _, _ in
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            },
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            clashClientFactory: { controller, secret in
                ClashAPIClient(
                    controller: controller,
                    secret: secret,
                    streamFactory: streams.stream(for:)
                )
            },
            automaticallyInitialize: false
        )

        state.startDashboardMonitoring()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertTrue(streams.requests.isEmpty)
        XCTAssertTrue(state.trafficHistory.isEmpty)
    }

    func testDashboardStreamFailureWarnsAndProxyStopCancelsRemainingStream() async throws {
        let streams = DashboardStreamFixture(sampleCount: 0, failTraffic: true)
        let fixture = try await makeModeFixture(
            initialMode: .systemProxy,
            clashClientFactory: { controller, secret in
                ClashAPIClient(
                    controller: controller,
                    secret: secret,
                    streamFactory: streams.stream(for:)
                )
            }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        fixture.state.startDashboardMonitoring()
        try await waitUntil {
            fixture.state.warnings.contains { $0.contains("流量推送已断开") }
        }
        XCTAssertEqual(fixture.state.status, .on)

        await fixture.state.stop()

        XCTAssertEqual(fixture.state.status, .off)
        try await waitUntil { streams.terminationCount == 2 }
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
        tunStopError: Error? = nil,
        tunStartFailureCalls: Set<Int> = [],
        clashClientFactory: AppState.ClashClientFactory? = nil
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
        let core = SingBoxProcess(binaryURL: try safeCoreExecutable(in: root))
        let privileged = FakePrivilegedLauncher(
            root: root,
            markerURL: markerURL,
            proxyRecoveryURL: proxyRecoveryURL,
            events: events,
            startError: tunStartError,
            stopError: tunStopError,
            startFailureCalls: tunStartFailureCalls
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
            clashClientFactory: clashClientFactory,
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
            network: network,
            events: events,
            proxyRecoveryURL: proxyRecoveryURL
        )
    }

    private func safeCoreExecutable(in root: URL) throws -> URL {
        let url = root.appending(path: "safe-test-core")
        let script = """
        #!/bin/sh
        if [ "$1" = "check" ]; then
          /bin/cat >/dev/null
          exit 0
        fi
        if [ "$1" = "run" ]; then
          /bin/cat >/dev/null
          exec /usr/bin/tail -f /dev/null
        fi
        exit 64
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }

    private func clashRuntime(from config: Data) throws -> (controller: String, secret: String) {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let experimental = try XCTUnwrap(root["experimental"] as? [String: Any])
        let clash = try XCTUnwrap(experimental["clash_api"] as? [String: Any])
        return (
            try XCTUnwrap(clash["external_controller"] as? String),
            try XCTUnwrap(clash["secret"] as? String)
        )
    }

    private func tunRouteExclusions(from config: Data) throws -> [String] {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["type"] as? String, "tun")
        return try XCTUnwrap(inbound["route_exclude_address"] as? [String])
    }

    private func tunStrictRoute(from config: Data) throws -> Bool {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let inbound = try XCTUnwrap((root["inbounds"] as? [[String: Any]])?.first)
        XCTAssertEqual(inbound["type"] as? String, "tun")
        return try XCTUnwrap(inbound["strict_route"] as? Bool)
    }

    private var customDNSSettings: DNSSettings {
        DNSSettings(
            domesticDoH: "https://1.1.1.1/domestic-query",
            remoteDoH: "https://9.9.9.9/remote-query"
        )
    }

    private func dnsURLs(from config: Data) throws -> DNSSettings {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: config) as? [String: Any])
        let dns = try XCTUnwrap(root["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        let domestic = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-cn" })
        let remote = try XCTUnwrap(servers.first { $0["tag"] as? String == "dns-remote" })

        func url(from server: [String: Any]) throws -> String {
            let host = try XCTUnwrap(server["server"] as? String)
            let path = try XCTUnwrap(server["path"] as? String)
            let port = server["server_port"] as? Int
            return "https://\(host)\(port.map { ":\($0)" } ?? "")\(path)"
        }
        return try DNSSettings(domesticDoH: url(from: domestic), remoteDoH: url(from: remote))
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

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
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
    let network: AppNetworkSetupRecorder
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
    private let startFailureCalls: Set<Int>
    private var active = false
    private var configs: [Data] = []
    private var startCallCount = 0

    init(
        root: URL,
        markerURL: URL? = nil,
        proxyRecoveryURL: URL? = nil,
        events: TakeoverEvents? = nil,
        startError: Error? = nil,
        stopError: Error? = nil,
        recoverError: Error? = nil,
        startFailureCalls: Set<Int> = []
    ) {
        self.markerURL = markerURL ?? root.appending(path: "fake-tun-active")
        self.proxyRecoveryURL = proxyRecoveryURL ?? root.appending(path: "proxy-recovery.json")
        self.events = events
        self.startError = startError
        self.stopError = stopError
        self.recoverError = recoverError
        self.startFailureCalls = startFailureCalls
    }

    func start(config: Data) async throws -> PrivilegedProcessRecord {
        startCallCount += 1
        await events?.append(.tunStart)
        if FileManager.default.fileExists(atPath: proxyRecoveryURL.path) {
            await events?.recordViolation("TUN started while system proxy recovery exists")
        }
        configs.append(config)
        if let startError { throw startError }
        if startFailureCalls.contains(startCallCount) { throw ModeTestError.startFailed }
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
    func attemptedConfigs() -> [Data] { configs }
}

private enum ModeTestError: Error {
    case startFailed
    case stopFailed
    case recoveryFailed
}

private enum DashboardStreamError: Error {
    case disconnected
}

private final class DashboardStreamFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let sampleCount: Int
    private let failTraffic: Bool
    private var storedRequests: [URLRequest] = []
    private var storedTerminationCount = 0

    init(sampleCount: Int, failTraffic: Bool = false) {
        self.sampleCount = sampleCount
        self.failTraffic = failTraffic
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    var terminationCount: Int {
        lock.withLock { storedTerminationCount }
    }

    func requestCount(path: String) -> Int {
        requests.filter { $0.url?.path == path }.count
    }

    func stream(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { storedRequests.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { storedTerminationCount += 1 }
            }
            switch request.url?.path {
            case "/traffic":
                if failTraffic {
                    continuation.finish(throwing: DashboardStreamError.disconnected)
                } else {
                    for index in 0..<sampleCount {
                        continuation.yield(Data("{\"up\":\(index),\"down\":\(index * 2)}".utf8))
                    }
                }
            case "/connections":
                continuation.yield(Data(
                    #"{"downloadTotal":0,"uploadTotal":0,"connections":[{},{}],"memory":4194304}"#.utf8
                ))
            default:
                continuation.finish(throwing: DashboardStreamError.disconnected)
            }
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
