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
        // 回归防护：后台管道必须放开 osascript 的捕获描述符，否则
        // `do shell script` 永不返回，配置写不进 FIFO，内核只会读到 EOF。
        XCTAssertTrue(script.contains("</dev/null"))
        XCTAssertTrue(script.contains("2>/dev/null"))
        XCTAssertTrue(script.contains("/bin/echo $!"))
        XCTAssertTrue(script.contains("Kong'\\\\''s App"))
        XCTAssertTrue(script.contains("kong'\\\\''s log.txt"))
        XCTAssertFalse(script.contains("runtime-secret"))
        // 回归防护：启动前先清掉本 App 残留的 root 内核（孤儿占路由会让新 TUN 起不来）。
        // 必须按进程名匹配（pgrep -x sing-box），绝不能用 pkill -f 匹配完整命令行——
        // 那会连正在执行本命令、命令行里也含内核路径的 shell 一起杀掉，导致配置写不进、内核读到 EOF。
        XCTAssertTrue(script.contains("pgrep -x sing-box"))
        XCTAssertFalse(script.contains("pkill -f"))
        // 路径匹配用 grep -F（固定字符串），不用 case glob——规避路径含 * ? [ 等 glob 元字符。
        XCTAssertTrue(script.contains("grep -F"))
        XCTAssertFalse(script.contains("case \"$("))
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
        // stop 同样用 grep -F 做固定字符串匹配。
        XCTAssertTrue(script.contains("grep -F"))
        XCTAssertFalse(script.contains("case \"$process\""))
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

    func testLifecycleStartVerifiesPIDAndWritesMinimalRecoveryRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = PrivilegedHarness(
            authorizationResponses: [.output(" 4321\n")],
            commands: [4321: "/Applications/Kong's App/sing-box run -c /dev/stdin"]
        )
        let launchedAt = Date(timeIntervalSince1970: 1_721_430_000)
        let launcher = makeLifecycleLauncher(root: root, harness: harness, now: { launchedAt })

        let record = try await launcher.start(config: Data("runtime-secret".utf8))

        XCTAssertEqual(record, PrivilegedProcessRecord(
            pid: 4321,
            binaryPath: "/Applications/Kong's App/sing-box",
            launchedAt: launchedAt
        ))
        let persisted = try JSONDecoder().decode(
            PrivilegedProcessRecord.self,
            from: Data(contentsOf: launcher.recoveryURL)
        )
        XCTAssertEqual(persisted, record)
        let sentConfigs = await harness.sentConfigs()
        let authorizationCount = await harness.authorizationCount()
        XCTAssertEqual(sentConfigs, [Data("runtime-secret".utf8)])
        XCTAssertEqual(authorizationCount, 1)
    }

    func testLifecycleStartFailuresNeverLeaveRecoveryRecord() async throws {
        let scenarios: [(AuthorizationResponse, String?, PrivilegedLauncherError)] = [
            (.failure(.authorizationCancelled), nil, .authorizationCancelled),
            (.output("not-a-pid"), nil, .invalidPID("not-a-pid")),
            (.output("4321"), "/usr/bin/other-process", .processMismatch(4321))
        ]

        for (response, command, expectedError) in scenarios {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let harness = PrivilegedHarness(
                authorizationResponses: [response],
                commands: command.map { [4321: $0] } ?? [:]
            )
            let launcher = makeLifecycleLauncher(root: root, harness: harness)

            do {
                _ = try await launcher.start(config: Data("secret".utf8))
                XCTFail("Expected lifecycle start to fail")
            } catch {
                XCTAssertEqual(error as? PrivilegedLauncherError, expectedError)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.recoveryURL.path))
        }
    }

    func testLifecycleStopRechecksIdentityAndKeepsRecordWhenAuthorizationFails() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = PrivilegedHarness(
            authorizationResponses: [.output("4321"), .failure(.authorizationCancelled)],
            commands: [4321: "/Applications/Kong's App/sing-box run -c /dev/stdin"]
        )
        let launcher = makeLifecycleLauncher(root: root, harness: harness)
        _ = try await launcher.start(config: Data("secret".utf8))

        do {
            try await launcher.stop()
            XCTFail("Expected stop authorization to fail")
        } catch {
            XCTAssertEqual(error as? PrivilegedLauncherError, .authorizationCancelled)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: launcher.recoveryURL.path))
        let authorizationCount = await harness.authorizationCount()
        XCTAssertEqual(authorizationCount, 2)
    }

    func testLifecycleRecoveryStopsExpectedProcessAndDeletesRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = PrivilegedHarness(
            authorizationResponses: [.output("4321"), .output("")],
            commands: [4321: "/Applications/Kong's App/sing-box run -c /dev/stdin"]
        )
        let firstLauncher = makeLifecycleLauncher(root: root, harness: harness)
        _ = try await firstLauncher.start(config: Data("secret".utf8))

        let restartedLauncher = makeLifecycleLauncher(root: root, harness: harness)
        try await restartedLauncher.recoverIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: restartedLauncher.recoveryURL.path))
        let scripts = await harness.authorizationScripts()
        XCTAssertEqual(scripts.count, 2)
        XCTAssertTrue(scripts[1].contains("/bin/kill -INT 4321"))
    }

    func testLifecycleRecoveryDeletesStaleRecordWithoutAuthorizing() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = PrivilegedHarness(
            authorizationResponses: [],
            commands: [4321: "/usr/bin/unrelated"]
        )
        let launcher = makeLifecycleLauncher(root: root, harness: harness)
        try await Storage(rootDirectory: root).writeAtomically(
            try JSONEncoder().encode(PrivilegedProcessRecord(
                pid: 4321,
                binaryPath: "/Applications/Kong's App/sing-box",
                launchedAt: Date(timeIntervalSince1970: 1)
            )),
            to: launcher.recoveryURL
        )

        try await launcher.recoverIfNeeded()

        XCTAssertFalse(FileManager.default.fileExists(atPath: launcher.recoveryURL.path))
        let authorizationCount = await harness.authorizationCount()
        XCTAssertEqual(authorizationCount, 0)
    }

    func testLifecyclePersistsNoRuntimeConfigOrCredentials() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = PrivilegedHarness(
            authorizationResponses: [.output("4321")],
            commands: [4321: "/Applications/Kong's App/sing-box run -c /dev/stdin"]
        )
        let launcher = makeLifecycleLauncher(root: root, harness: harness)
        let sensitiveValues = ["unique-clash-secret", "unique-node-password", "54321"]
        let config = Data(sensitiveValues.joined(separator: "|").utf8)

        _ = try await launcher.start(config: config)

        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        let files = (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        XCTAssertEqual(
            Set(files.map(\.lastPathComponent)),
            Set(["tun-recovery.json", "sing-box-tun.log"])
        )
        let tunLog = root.appending(path: "logs/sing-box-tun.log")
        XCTAssertEqual(try Data(contentsOf: tunLog), Data())
        let permissions = try FileManager.default.attributesOfItem(atPath: tunLog.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        for file in files {
            let contents = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            for value in sensitiveValues {
                XCTAssertFalse(contents.contains(value), "Persisted sensitive value in \(file.path)")
            }
        }
    }

    func testOSAScriptAuthorizerUsesFixedExecutableAndMapsFailures() async throws {
        let recorder = ProcessInvocationRecorder()
        let success = try await OSAScriptAuthorizer.run(
            script: "return 4321",
            timeout: 7,
            runner: { executable, arguments, timeout in
                await recorder.record(executable: executable, arguments: arguments, timeout: timeout)
                return ProcessResult(exitCode: 0, stdout: "4321\n", stderr: "")
            }
        )
        XCTAssertEqual(success, "4321\n")
        let recordedInvocation = await recorder.lastInvocation()
        let invocation = try XCTUnwrap(recordedInvocation)
        XCTAssertEqual(invocation.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(invocation.arguments, ["-e", "return 4321"])
        XCTAssertEqual(invocation.timeout, 7)

        do {
            _ = try await OSAScriptAuthorizer.run(
                script: "cancel",
                timeout: 7,
                runner: { _, _, _ in
                    ProcessResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
                }
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? PrivilegedLauncherError, .authorizationCancelled)
        }

        do {
            _ = try await OSAScriptAuthorizer.run(
                script: "fail",
                timeout: 7,
                runner: { _, _, _ in
                    ProcessResult(exitCode: 2, stdout: "", stderr: "authorization denied")
                }
            )
            XCTFail("Expected authorization failure")
        } catch {
            XCTAssertEqual(
                error as? PrivilegedLauncherError,
                .authorizationFailed("authorization denied")
            )
        }

        do {
            _ = try await OSAScriptAuthorizer.run(
                script: "timeout",
                timeout: 7,
                runner: { _, _, _ in throw ProcessRunnerError.timedOut }
            )
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? PrivilegedLauncherError, .authorizationTimedOut)
        }
    }

    private func makeLifecycleLauncher(
        root: URL,
        harness: PrivilegedHarness,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> PrivilegedLauncher {
        PrivilegedLauncher(
            storage: Storage(rootDirectory: root),
            binaryURL: URL(fileURLWithPath: "/Applications/Kong's App/sing-box"),
            authorizationTimeout: 7,
            now: now,
            authorizer: { script, timeout in
                try await harness.authorize(script: script, timeout: timeout)
            },
            configTransport: { data, runtimeDirectory, launch in
                try await harness.send(data, runtimeDirectory: runtimeDirectory, launch: launch)
            },
            processInspector: { pid in
                await harness.command(for: pid)
            }
        )
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
    private var completionURL: URL?

    func startReading(from url: URL) throws {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-pipe-capture-\(UUID().uuidString)")
        let completionURL = outputURL.appendingPathExtension("done")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "/bin/cat \"$1\"; /usr/bin/touch \"$2\"",
            "kongshan-pipe-reader",
            url.path,
            completionURL.path
        ]
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        self.outputHandle = outputHandle
        self.outputURL = outputURL
        self.completionURL = completionURL
    }

    func result() async throws -> Data {
        guard let process, let outputHandle, let outputURL, let completionURL else {
            throw TestError.missingReader
        }
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: completionURL)
        }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: completionURL.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard FileManager.default.fileExists(atPath: completionURL.path) else {
            if process.isRunning { process.terminate() }
            throw TestError.readerFailed
        }
        try outputHandle.close()
        return try Data(contentsOf: outputURL)
    }
}

private enum TestError: Error, Equatable {
    case authorizationCancelled
    case missingReader
    case readerFailed
}

private enum AuthorizationResponse: Sendable {
    case output(String)
    case failure(PrivilegedLauncherError)
}

private actor PrivilegedHarness {
    private var responses: [AuthorizationResponse]
    private let commands: [Int32: String]
    private var scripts: [String] = []
    private var configs: [Data] = []

    init(authorizationResponses: [AuthorizationResponse], commands: [Int32: String]) {
        responses = authorizationResponses
        self.commands = commands
    }

    func authorize(script: String, timeout: TimeInterval) throws -> String {
        scripts.append(script)
        guard !responses.isEmpty else {
            throw PrivilegedLauncherError.authorizationFailed("missing fake response")
        }
        switch responses.removeFirst() {
        case let .output(output): return output
        case let .failure(error): throw error
        }
    }

    func send(
        _ data: Data,
        runtimeDirectory: URL,
        launch: @Sendable (URL) async throws -> Int32
    ) async throws -> Int32 {
        configs.append(data)
        return try await launch(runtimeDirectory.appending(path: "fake-config.fifo"))
    }

    func command(for pid: Int32) -> String? {
        commands[pid]
    }

    func sentConfigs() -> [Data] { configs }
    func authorizationCount() -> Int { scripts.count }
    func authorizationScripts() -> [String] { scripts }
}

private actor ProcessInvocationRecorder {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    private var invocation: Invocation?

    func record(executable: URL, arguments: [String], timeout: TimeInterval) {
        invocation = Invocation(executable: executable, arguments: arguments, timeout: timeout)
    }

    func lastInvocation() -> Invocation? { invocation }
}
