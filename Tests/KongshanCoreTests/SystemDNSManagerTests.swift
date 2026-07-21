import Foundation
import XCTest
@testable import KongshanCore

final class SystemDNSManagerTests: XCTestCase {
    func testServersParsingHandlesNoServersMessageAndLists() {
        XCTAssertEqual(
            SystemDNSCommands.servers(from: "There aren't any DNS Servers set on Wi-Fi.\n"),
            []
        )
        XCTAssertEqual(
            SystemDNSCommands.servers(from: "8.8.8.8\n1.1.1.1\n"),
            ["8.8.8.8", "1.1.1.1"]
        )
        XCTAssertEqual(
            SystemDNSCommands.set(service: "Wi-Fi", servers: []),
            ["-setdnsservers", "Wi-Fi", "Empty"]
        )
        XCTAssertEqual(
            SystemDNSCommands.set(service: "Wi-Fi", servers: ["8.8.8.8", "1.1.1.1"]),
            ["-setdnsservers", "Wi-Fi", "8.8.8.8", "1.1.1.1"]
        )
    }

    func testTunSettingsDeriveDNSServerAddressInsideTunSubnet() {
        XCTAssertEqual(TunSettings.defaults.dnsServerAddress, "172.19.0.2")
        var custom = TunSettings.defaults
        custom.addresses = ["10.66.0.1/24", "fdfe::1/126"]
        XCTAssertEqual(custom.dnsServerAddress, "10.66.0.2")
        custom.addresses = ["not-an-address"]
        XCTAssertEqual(custom.dnsServerAddress, "172.19.0.2")
    }

    func testEnableSnapshotsBeforeMutatingThenRestoreWritesBackAndDeletesSnapshot() async throws {
        let root = temporaryDNSDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DNSSetupRecorder(
            recoveryURL: root.appending(path: "dns-recovery.json"),
            services: ["Wi-Fi", "Thunderbolt Bridge"],
            dnsByService: ["Wi-Fi": ["8.8.8.8", "1.1.1.1"]]
        )
        let manager = SystemDNSManager(
            storage: Storage(rootDirectory: root),
            runner: recorder.run(arguments:timeout:)
        )

        try await manager.enable(server: "172.19.0.2")

        let snapshotBeforeMutation = await recorder.snapshotExistedBeforeFirstMutation
        XCTAssertTrue(snapshotBeforeMutation, "必须先落盘快照再修改系统 DNS")
        var mutations = await recorder.mutationArguments
        XCTAssertEqual(mutations, [
            ["-setdnsservers", "Wi-Fi", "172.19.0.2"],
            ["-setdnsservers", "Thunderbolt Bridge", "172.19.0.2"]
        ])

        try await manager.restore()

        mutations = await recorder.mutationArguments
        XCTAssertEqual(Array(mutations.dropFirst(2)), [
            ["-setdnsservers", "Wi-Fi", "8.8.8.8", "1.1.1.1"],
            ["-setdnsservers", "Thunderbolt Bridge", "Empty"]
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.recoveryURL.path))
    }

    func testEnableRefusesWhenRecoveryPendingAndRollsBackOnFailure() async throws {
        let root = temporaryDNSDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recoveryURL = root.appending(path: "dns-recovery.json")
        let recorder = DNSSetupRecorder(
            recoveryURL: recoveryURL,
            services: ["Wi-Fi", "Thunderbolt Bridge"],
            dnsByService: ["Wi-Fi": ["9.9.9.9"]],
            failOnceFor: ["-setdnsservers", "Thunderbolt Bridge", "172.19.0.2"]
        )
        let manager = SystemDNSManager(
            storage: Storage(rootDirectory: root),
            runner: recorder.run(arguments:timeout:)
        )

        // 第二个服务写入失败 → 整体回滚：Wi-Fi 恢复原值，快照删除。
        do {
            try await manager.enable(server: "172.19.0.2")
            XCTFail("Expected enable to fail")
        } catch {
            // expected
        }
        let mutations = await recorder.mutationArguments
        XCTAssertTrue(mutations.contains(["-setdnsservers", "Wi-Fi", "9.9.9.9"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))

        // 残留快照存在时拒绝再次接管。
        try Data("{\"version\":1,\"capturedAt\":0,\"services\":[]}".utf8).write(to: recoveryURL)
        do {
            try await manager.enable(server: "172.19.0.2")
            XCTFail("Expected recoveryPending")
        } catch let error as SystemDNSError {
            XCTAssertEqual(error, .recoveryPending)
        }
    }

    func testReassertOnlyTouchesStaleServicesAndExtendsSnapshotForRestore() async throws {
        let root = temporaryDNSDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DNSSetupRecorder(
            recoveryURL: root.appending(path: "dns-recovery.json"),
            services: ["Wi-Fi"],
            dnsByService: ["Wi-Fi": ["8.8.8.8"]]
        )
        let manager = SystemDNSManager(
            storage: Storage(rootDirectory: root),
            runner: recorder.run(arguments:timeout:)
        )
        try await manager.enable(server: "172.19.0.2")

        // 模拟接入 iPhone USB：新服务出现且 DNS 是 DHCP 默认。
        await recorder.setServices(["Wi-Fi", "iPhone USB"])
        try await manager.reassert(server: "172.19.0.2")

        var mutations = await recorder.mutationArguments
        XCTAssertEqual(Array(mutations.dropFirst(1)), [
            ["-setdnsservers", "iPhone USB", "172.19.0.2"]
        ], "已指向我们的 Wi-Fi 不应被重复设置")

        // 还原时新服务也要一并复位（写回 Empty）。
        try await manager.restore()
        mutations = await recorder.mutationArguments
        XCTAssertEqual(Array(mutations.dropFirst(2)), [
            ["-setdnsservers", "Wi-Fi", "8.8.8.8"],
            ["-setdnsservers", "iPhone USB", "Empty"]
        ])
    }

    func testReassertAndRestoreWithoutSnapshotDoNothing() async throws {
        let root = temporaryDNSDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = DNSSetupRecorder(
            recoveryURL: root.appending(path: "dns-recovery.json"),
            services: ["Wi-Fi"]
        )
        let manager = SystemDNSManager(
            storage: Storage(rootDirectory: root),
            runner: recorder.run(arguments:timeout:)
        )

        try await manager.reassert(server: "172.19.0.2")
        try await manager.restore()
        try await manager.recoverIfNeeded()

        let arguments = await recorder.arguments
        XCTAssertTrue(arguments.isEmpty, "没有活动快照时不得执行任何 networksetup 命令")
    }

    private func temporaryDNSDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-dns-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// 模拟 networksetup 的 DNS 相关子命令。set 会真的更新内部映射，
/// 让 reassert 的「已指向我们」判断走真实读回来的值。
private actor DNSSetupRecorder {
    private let recoveryURL: URL
    private var services: [String]
    private var dnsByService: [String: [String]]
    private var failOnceFor: [String]?
    private(set) var arguments: [[String]] = []
    private(set) var mutationArguments: [[String]] = []
    private(set) var snapshotExistedBeforeFirstMutation = false

    init(
        recoveryURL: URL,
        services: [String],
        dnsByService: [String: [String]] = [:],
        failOnceFor: [String]? = nil
    ) {
        self.recoveryURL = recoveryURL
        self.services = services
        self.dnsByService = dnsByService
        self.failOnceFor = failOnceFor
    }

    func setServices(_ services: [String]) {
        self.services = services
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        self.arguments.append(arguments)
        if failOnceFor == arguments {
            failOnceFor = nil
            return ProcessResult(exitCode: 7, stdout: "", stderr: "simulated dns failure")
        }
        switch arguments.first {
        case "-listallnetworkservices":
            let listing = (["An asterisk (*) denotes that a network service is disabled."] + services)
                .joined(separator: "\n")
            return ProcessResult(exitCode: 0, stdout: listing, stderr: "")
        case "-getdnsservers":
            let service = arguments.count > 1 ? arguments[1] : ""
            let servers = dnsByService[service] ?? []
            let output = servers.isEmpty
                ? "There aren't any DNS Servers set on \(service).\n"
                : servers.joined(separator: "\n")
            return ProcessResult(exitCode: 0, stdout: output, stderr: "")
        case "-setdnsservers":
            if mutationArguments.isEmpty {
                snapshotExistedBeforeFirstMutation = FileManager.default.fileExists(atPath: recoveryURL.path)
            }
            mutationArguments.append(arguments)
            let service = arguments.count > 1 ? arguments[1] : ""
            let values = Array(arguments.dropFirst(2))
            dnsByService[service] = values == ["Empty"] ? [] : values
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        default:
            return ProcessResult(exitCode: 0, stdout: "", stderr: "")
        }
    }
}
