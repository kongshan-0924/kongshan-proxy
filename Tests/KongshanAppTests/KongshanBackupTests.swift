import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

@MainActor
final class KongshanBackupTests: XCTestCase {
    func testAppStateExportAndImportRestoresManualNodesAndRules() async throws {
        let sourceRoot = temporaryDirectory()
        let targetRoot = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: sourceRoot)
            try? FileManager.default.removeItem(at: targetRoot)
        }
        let source = AppState(
            storage: Storage(rootDirectory: sourceRoot),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
        await source.addManual(ManualHysteria2(
            name: "手动备份节点",
            server: "hy.example.com",
            port: 443,
            password: "secret",
            sni: "hy.example.com",
            skipCertificateVerification: false,
            obfsPassword: nil,
            uploadMbps: 20,
            downloadMbps: 100
        ))
        await source.upsertProcessRule(processName: "Game", action: .direct, proxyTarget: nil)
        let data = try await source.exportBackup()
        let target = AppState(
            storage: Storage(rootDirectory: targetRoot),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )

        await target.importBackup(data)

        XCTAssertEqual(target.manualNodes.map(\.name), ["手动备份节点"])
        XCTAssertEqual(target.processRules.map(\.value), ["Game"])
        XCTAssertNil(target.errorMessage)
    }

    func testFailedImportDoesNotMutateExistingState() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
        await state.addManual(ManualHysteria2(
            name: "保留节点",
            server: "keep.example.com",
            port: 443,
            password: "secret",
            sni: "keep.example.com",
            skipCertificateVerification: false,
            obfsPassword: nil,
            uploadMbps: 20,
            downloadMbps: 100
        ))

        await state.importBackup(Data("broken".utf8))

        XCTAssertEqual(state.manualNodes.map(\.name), ["保留节点"])
        XCTAssertTrue(state.errorMessage?.contains("导入备份失败") == true)
    }

    func testVersionOneRoundTripsSettingsNodesAndSubscriptionCache() throws {
        let node = ProxyNode(
            name: "backup-node",
            protocolType: .shadowsocks,
            server: "example.com",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
        let sourceID = UUID()
        let backup = KongshanBackup(
            version: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            subscriptions: [SubscriptionSource(id: sourceID, name: "sub", url: URL(string: "https://example.com/sub")!)],
            manualNodes: [node],
            settings: .defaults,
            routingSettings: .defaults,
            subscriptionCaches: [sourceID: Data("proxies: []".utf8)]
        )

        let decoded = try KongshanBackup.decodeValidated(from: JSONEncoder().encode(backup))

        XCTAssertEqual(decoded, backup)
        XCTAssertEqual(decoded.manualNodes.first?.password, "secret")
        XCTAssertEqual(decoded.subscriptionCaches[sourceID], Data("proxies: []".utf8))
    }

    func testUnsupportedVersionIsRejected() throws {
        let backup = KongshanBackup(
            version: 99,
            createdAt: Date(),
            subscriptions: [],
            manualNodes: [],
            settings: .defaults,
            routingSettings: .defaults,
            subscriptionCaches: [:]
        )

        XCTAssertThrowsError(try KongshanBackup.decodeValidated(from: JSONEncoder().encode(backup))) { error in
            XCTAssertEqual(error as? KongshanBackupError, .unsupportedVersion(99))
        }
    }

    func testMalformedDataIsRejected() {
        XCTAssertThrowsError(try KongshanBackup.decodeValidated(from: Data("not json".utf8)))
    }
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
