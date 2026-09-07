import Foundation
import XCTest
@testable import KongshanCore

/// 切配置时更新绕过域名：**不许对"此刻不在系统列表中"的服务下命令**。
///
/// v0.1.99 起，还原不了的服务会留在快照里等它回来（待还原保留）。对这类服务写 networksetup
/// 必然失败，而报错恰好是 `Unable to find item in network database.`——与真正的瞬时抖动同一句话，
/// 于是被重试逻辑当成抖动白等约 3 秒，回滚循环再撞一次再等 3 秒，最后整次配置应用被推翻。
/// 真机 2026-09-04 起 5 次「当前配置应用失败，已回滚」全部由此而来，且每次必现。
final class BypassUpdateAbsentServiceTests: XCTestCase {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-bypass-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSnapshot(_ names: [String], to root: URL) throws {
        let services = names.map {
            NetworkServiceProxySnapshot(
                name: $0,
                http: ProxyEndpointState(enabled: false, server: "", port: 0),
                https: ProxyEndpointState(enabled: false, server: "", port: 0),
                socks: ProxyEndpointState(enabled: false, server: "", port: 0),
                bypassDomains: []
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(ProxyRecoverySnapshot(services: services))
            .write(to: root.appending(path: "proxy-recovery.json"))
    }

    func testAbsentServiceInSnapshotIsSkippedAndUpdateSucceeds() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 快照里有 Shadowrocket（待还原），系统里只有 Wi-Fi。
        try writeSnapshot(["Wi-Fi", "Shadowrocket"], to: root)

        let runner = BypassRecorder(services: ["Wi-Fi"])
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        try await manager.updateBypassDomains(to: ["*.cn"], rollbackTo: ["localhost"])

        let touched = await runner.bypassTargets
        XCTAssertEqual(touched, ["Wi-Fi"], "只该给当前存在的服务下命令，实际：\(touched)")
        let failed = await runner.sawAbsentService
        XCTAssertFalse(failed, "对缺席服务下命令必然失败，会把整次配置应用拖垮")
    }

    /// 快照里的服务全都缺席时直接成功返回，不发任何命令、也不报错。
    func testAllAbsentIsANoOp() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSnapshot(["Shadowrocket"], to: root)

        let runner = BypassRecorder(services: ["Wi-Fi"])
        let manager = SystemProxyManager(
            storage: Storage(rootDirectory: root),
            runner: runner.run(arguments:timeout:)
        )

        try await manager.updateBypassDomains(to: ["*.cn"], rollbackTo: ["localhost"])

        let touched = await runner.bypassTargets
        XCTAssertTrue(touched.isEmpty, "没有可更新的服务时不该发命令，实际：\(touched)")
    }
}

/// 只认识列出来的服务；对别的服务一律回真机那句报错。
private actor BypassRecorder {
    private let services: [String]
    private(set) var bypassTargets: [String] = []
    private(set) var sawAbsentService = false

    init(services: [String]) {
        self.services = services
    }

    func run(arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        if arguments.first == "-listallnetworkservices" {
            let listing = (["An asterisk (*) denotes that a network service is disabled."] + services)
                .joined(separator: "\n")
            return ProcessResult(exitCode: 0, stdout: listing, stderr: "")
        }
        guard arguments.count > 1 else { return ProcessResult(exitCode: 0, stdout: "", stderr: "") }
        let service = arguments[1]
        guard services.contains(service) else {
            sawAbsentService = true
            return ProcessResult(
                exitCode: 8,
                stdout: "",
                stderr: "** Error: Unable to find item in network database."
            )
        }
        if arguments.first == "-setproxybypassdomains" { bypassTargets.append(service) }
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
