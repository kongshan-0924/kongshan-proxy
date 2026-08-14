import Foundation
import XCTest
@testable import KongshanCore

final class SSHProxyConfigManagerTests: XCTestCase {
    func testApplyCreatesManagedIncludeWithoutChangingExistingHosts() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appending(path: ".ssh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let config = ssh.appending(path: "config")
        try Data("Host existing\n    User alice\n".utf8).write(to: config)
        let manager = SSHProxyConfigManager(homeDirectory: home)

        try await manager.apply(
            targets: [SSHProxyTarget(address: "118.69.52.186", port: 22_235)],
            relayPort: 36_815
        )

        let main = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(main.hasPrefix("\(SSHProxyConfigManager.blockStart)\n\(SSHProxyConfigManager.includeLine)"))
        XCTAssertTrue(main.contains("Host existing\n    User alice"))
        let managed = try String(
            contentsOf: ssh.appending(path: "kongshan-proxy.conf"),
            encoding: .utf8
        )
        XCTAssertTrue(managed.contains("Match host 118.69.52.186 exec \"/bin/test %p = 22235\""))
        XCTAssertTrue(managed.contains("-x 127.0.0.1:36815 -X 5 %h %p"))
        XCTAssertEqual(try permissions(config), 0o600)
        XCTAssertEqual(try permissions(ssh.appending(path: "kongshan-proxy.conf")), 0o600)
    }

    func testApplyUpdatesManagedFileAndDoesNotDuplicateInclude() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = SSHProxyConfigManager(homeDirectory: home)

        try await manager.apply(targets: [SSHProxyTarget(address: "203.0.113.8")], relayPort: 30_001)
        try await manager.apply(targets: [SSHProxyTarget(address: "2001:db8::1")], relayPort: 30_002)

        let main = try String(contentsOf: home.appending(path: ".ssh/config"), encoding: .utf8)
        XCTAssertEqual(main.components(separatedBy: SSHProxyConfigManager.blockStart).count - 1, 1)
        let managed = try String(
            contentsOf: home.appending(path: ".ssh/kongshan-proxy.conf"),
            encoding: .utf8
        )
        XCTAssertFalse(managed.contains("203.0.113.8"))
        XCTAssertTrue(managed.contains("Match host 2001:db8::1 exec \"/bin/test %p = 22\""))
        XCTAssertTrue(managed.contains("127.0.0.1:30002"))
    }

    func testEmptyTargetsRemoveOnlyManagedFilesAndBlock() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = SSHProxyConfigManager(homeDirectory: home)
        try await manager.apply(targets: [SSHProxyTarget(address: "203.0.113.8")], relayPort: 30_001)

        try await manager.apply(targets: [], relayPort: nil)

        let main = try String(contentsOf: home.appending(path: ".ssh/config"), encoding: .utf8)
        XCTAssertFalse(main.contains(SSHProxyConfigManager.blockStart))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: ".ssh/kongshan-proxy.conf").path))
    }

    func testMalformedManagedBlockFailsClosed() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appending(path: ".ssh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let config = ssh.appending(path: "config")
        let original = "\(SSHProxyConfigManager.blockStart)\nHost existing\n"
        try Data(original.utf8).write(to: config)
        let manager = SSHProxyConfigManager(homeDirectory: home)

        await XCTAssertThrowsErrorAsync {
            try await manager.apply(targets: [SSHProxyTarget(address: "203.0.113.8")], relayPort: 30_001)
        }

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), original)
    }

    func testSymbolicSSHDirectoryFailsClosed() async throws {
        let home = temporaryDirectory()
        let linkedDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: linkedDirectory)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".ssh"),
            withDestinationURL: linkedDirectory
        )
        let manager = SSHProxyConfigManager(homeDirectory: home)

        await XCTAssertThrowsErrorAsync {
            try await manager.apply(targets: [SSHProxyTarget(address: "203.0.113.8")], relayPort: 30_001)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedDirectory.appending(path: "config").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedDirectory.appending(path: "kongshan-proxy.conf").path))
    }

    func testRemovingThroughSymbolicSSHDirectoryFailsClosed() async throws {
        let home = temporaryDirectory()
        let linkedDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: linkedDirectory)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        let linkedConfig = linkedDirectory.appending(path: "config")
        let original = "\(SSHProxyConfigManager.blockStart)\n\(SSHProxyConfigManager.includeLine)\n\(SSHProxyConfigManager.blockEnd)\n"
        try Data(original.utf8).write(to: linkedConfig)
        try FileManager.default.createSymbolicLink(
            at: home.appending(path: ".ssh"),
            withDestinationURL: linkedDirectory
        )
        let manager = SSHProxyConfigManager(homeDirectory: home)

        await XCTAssertThrowsErrorAsync {
            try await manager.apply(targets: [], relayPort: nil)
        }

        XCTAssertEqual(try String(contentsOf: linkedConfig, encoding: .utf8), original)
    }

    /// 没有托管痕迹时的清理必须是无操作：符号链接检查只该拦住“真要写入”的路径。
    /// 否则把 ~/.ssh/config 软链到 dotfiles 仓库、且从未用过本功能的用户，
    /// 每次停止代理和应用分流规则都会被这条 fail-closed 拖失败。
    func testRemovingWithoutManagedFootprintIsNoOpEvenWhenConfigIsSymlink() async throws {
        let home = temporaryDirectory()
        let external = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: external)
        }
        let ssh = home.appending(path: ".ssh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let linkedConfig = external.appending(path: "ssh-config")
        let original = "Host existing\n    User alice\n"
        try Data(original.utf8).write(to: linkedConfig)
        let configLink = ssh.appending(path: "config")
        try FileManager.default.createSymbolicLink(at: configLink, withDestinationURL: linkedConfig)
        let manager = SSHProxyConfigManager(homeDirectory: home)

        try await manager.apply(targets: [], relayPort: nil)

        XCTAssertEqual(try String(contentsOf: linkedConfig, encoding: .utf8), original)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: configLink.path)[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
    }

    func testDanglingManagedFileSymlinkFailsClosed() async throws {
        let home = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let ssh = home.appending(path: ".ssh", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: ssh.appending(path: "kongshan-proxy.conf"),
            withDestinationURL: home.appending(path: "missing-target")
        )
        let manager = SSHProxyConfigManager(homeDirectory: home)

        await XCTAssertThrowsErrorAsync {
            try await manager.apply(targets: [SSHProxyTarget(address: "203.0.113.8")], relayPort: 30_001)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appending(path: "missing-target").path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
