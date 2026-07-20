import Foundation
import XCTest
@testable import KongshanCore

final class SingBoxProcessTests: XCTestCase {
    func testProcessRunnerCapturesInputOutputAndError() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-c", "read value; print -r -- out:$value; print -r -u2 -- warning"],
            standardInput: Data("hello\n".utf8),
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "out:hello\n")
        XCTAssertEqual(result.stderr, "warning\n")
    }

    func testProcessRunnerTerminatesAfterTimeout() async {
        do {
            _ = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", "sleep 2"],
                timeout: 0.05
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut)
        }
    }

    func testSingBoxChecksGeneratedConfigFromStandardInput() async throws {
        let node = ProxyNode(
            name: "ss",
            protocolType: .shadowsocks,
            server: "1.1.1.1",
            port: 443,
            password: "secret",
            method: "aes-128-gcm"
        )
        let config = try ConfigGenerator.generate(ConfigInput(
            nodes: [node],
            selectedNodeID: node.id,
            runtime: RuntimeParameters(mixedPort: 51_080, clashPort: 51_909, secret: "memory-only")
        ))
        let core = SingBoxProcess(binaryURL: packageRoot.appending(path: "Vendor/sing-box/sing-box"))

        let result = try await core.check(config: config)

        XCTAssertEqual(result.exitCode, 0, result.stderr)
    }

    func testSingBoxProcessStartsAndStops() async throws {
        let script = try makeScript("#!/bin/zsh\ncat >/dev/null\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let core = SingBoxProcess(binaryURL: script)

        try await core.start(config: Data("{}".utf8))

        let running = await core.isRunning
        XCTAssertTrue(running)
        await core.stop()
        let stopped = await core.isRunning
        XCTAssertFalse(stopped)
    }

    func testRestartReplacesRunningProcessWithNewConfig() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "configs.log")
        let script = try makeScript("#!/bin/zsh\nvalue=$(cat)\nprint -r -- $value >> '\(log.path)'\nsleep 10\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let core = SingBoxProcess(binaryURL: script)

        try await core.start(config: Data("old-config".utf8))
        try await waitForLineCount(1, at: log)
        try await core.restart(config: Data("new-config".utf8))
        try await waitForLineCount(2, at: log)

        let running = await core.isRunning
        XCTAssertTrue(running)
        XCTAssertEqual(
            try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init),
            ["old-config", "new-config"]
        )
        await core.stop()
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeScript(_ source: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = directory.appending(path: "fake-sing-box")
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private func waitForLineCount(_ count: Int, at url: URL) async throws {
        for _ in 0..<50 {
            let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").count ?? 0
            if lines >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for process input")
    }
}
