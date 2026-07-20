import Foundation
import XCTest
@testable import KongshanCore

final class PrivilegedLauncherTests: XCTestCase {
    func testStartCommandUsesOnlyFixedElevatedLaunchShapeAndEscapesPaths() {
        let script = PrivilegedCommandBuilder.start(
            binaryURL: URL(fileURLWithPath: "/Applications/Kong's App/sing-box"),
            fifoURL: URL(fileURLWithPath: "/tmp/config pipe.fifo"),
            logURL: URL(fileURLWithPath: "/tmp/kong's log.txt")
        )

        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.contains("with prompt \"kongshan 需要管理员权限启动 TUN\""))
        XCTAssertTrue(script.hasSuffix("with administrator privileges"))
        XCTAssertTrue(script.contains("/bin/cat"))
        XCTAssertTrue(script.contains("run -c /dev/stdin"))
        XCTAssertTrue(script.contains("/bin/echo $!"))
        XCTAssertTrue(script.contains("Kong'\\\\''s App"))
        XCTAssertTrue(script.contains("kong'\\\\''s log.txt"))
        XCTAssertFalse(script.contains("runtime-secret"))
    }

    func testStopCommandRechecksProcessCommandBeforeSendingInterrupt() throws {
        let script = try PrivilegedCommandBuilder.stop(
            pid: 42,
            binaryURL: URL(fileURLWithPath: "/Applications/Kong's App/sing-box")
        )

        XCTAssertTrue(script.contains("/bin/ps -p 42 -o command="))
        XCTAssertTrue(script.contains("/bin/kill -INT 42"))
        XCTAssertTrue(script.contains("Kong'\\\\''s App"))
        XCTAssertTrue(script.contains("exit 64"))
        XCTAssertThrowsError(try PrivilegedCommandBuilder.stop(
            pid: 1,
            binaryURL: URL(fileURLWithPath: "/tmp/sing-box")
        )) { error in
            XCTAssertEqual(error as? PrivilegedLauncherError, .invalidPID("1"))
        }
    }

    func testPIDParserAcceptsOnePositiveLineAndRejectsUnsafeValues() throws {
        XCTAssertEqual(try PrivilegedCommandBuilder.parsePID(" 12345\r"), 12_345)
        for value in ["", "abc", "1", "-4", "999999999999999999"] {
            XCTAssertThrowsError(try PrivilegedCommandBuilder.parsePID(value)) { error in
                XCTAssertEqual(error as? PrivilegedLauncherError, .invalidPID(value.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }

    func testGeneratedAppleScriptsCompileWithoutExecuting() async throws {
        let binary = URL(fileURLWithPath: "/Applications/Kong's App/sing-box")
        let scripts = [
            PrivilegedCommandBuilder.start(
                binaryURL: binary,
                fifoURL: URL(fileURLWithPath: "/tmp/config pipe.fifo"),
                logURL: URL(fileURLWithPath: "/tmp/kong's log.txt")
            ),
            try PrivilegedCommandBuilder.stop(pid: 42, binaryURL: binary)
        ]

        for script in scripts {
            let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).scpt")
            defer { try? FileManager.default.removeItem(at: output) }
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/osacompile"),
                arguments: ["-o", output.path, "-e", script],
                timeout: 5
            )
            XCTAssertEqual(result.exitCode, 0, result.stderr)
        }
    }

    func testPOSIXConfigPipeTransfersLargeDataAndRemovesFIFO() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data((0..<262_144).map { UInt8($0 % 251) })
        let capture = PipeCapture()

        let pid = try await POSIXConfigPipe.send(
            data,
            runtimeDirectory: root,
            launch: { fifoURL in
                try await capture.startReading(from: fifoURL)
                return 54_321
            }
        )

        XCTAssertEqual(pid, 54_321)
        let captured = try await capture.result()
        XCTAssertEqual(captured, data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o700)
    }

    func testPOSIXConfigPipeCleansUpWhenLaunchFails() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await POSIXConfigPipe.send(
                Data("secret".utf8),
                runtimeDirectory: root,
                launch: { _ in throw TestError.authorizationCancelled }
            )
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertEqual(error as? TestError, .authorizationCancelled)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kongshan-privileged-launcher-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}

private actor PipeCapture {
    private var process: Process?
    private var outputHandle: FileHandle?
    private var outputURL: URL?

    func startReading(from url: URL) throws {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-pipe-capture-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        process.executableURL = URL(fileURLWithPath: "/bin/cat")
        process.arguments = [url.path]
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.outputHandle = outputHandle
        self.outputURL = outputURL
    }

    func result() throws -> Data {
        guard let process, let outputHandle, let outputURL else { throw TestError.missingReader }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        process.waitUntilExit()
        try outputHandle.close()
        guard process.terminationStatus == 0 else { throw TestError.readerFailed }
        return try Data(contentsOf: outputURL)
    }
}

private enum TestError: Error, Equatable {
    case authorizationCancelled
    case missingReader
    case readerFailed
}
