import Darwin
import Foundation

public enum PrivilegedLauncherError: Error, Equatable, LocalizedError {
    case invalidPID(String)
    case pipeFailed(String)
    case authorizationCancelled
    case authorizationTimedOut
    case authorizationFailed(String)
    case processMismatch(Int32)
    case processInspectionFailed(String)
    case invalidRecoveryRecord(String)
    case recoveryPending(Int32)
    case operationInProgress
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPID(value):
            "管理员进程返回了无效 PID：\(value)"
        case let .pipeFailed(message):
            "无法安全传递 TUN 配置：\(message)"
        case .authorizationCancelled:
            "已取消 TUN 管理员授权"
        case .authorizationTimedOut:
            "TUN 管理员授权超时"
        case let .authorizationFailed(message):
            "TUN 管理员授权失败：\(message)"
        case let .processMismatch(pid):
            "TUN 进程身份校验失败（PID \(pid)）"
        case let .processInspectionFailed(message):
            "无法检查 TUN 进程：\(message)"
        case let .invalidRecoveryRecord(message):
            "TUN 恢复记录无效：\(message)"
        case let .recoveryPending(pid):
            "存在待恢复的 TUN 进程（PID \(pid)）"
        case .operationInProgress:
            "另一项 TUN 操作仍在执行"
        case let .persistenceFailed(message):
            "无法保存 TUN 恢复记录：\(message)"
        }
    }
}

public struct PrivilegedProcessRecord: Codable, Equatable, Sendable {
    public let pid: Int32
    public let binaryPath: String
    public let launchedAt: Date

    public init(pid: Int32, binaryPath: String, launchedAt: Date) {
        self.pid = pid
        self.binaryPath = binaryPath
        self.launchedAt = launchedAt
    }
}

public typealias PrivilegedAuthorizer = @Sendable (
    _ appleScript: String,
    _ timeout: TimeInterval
) async throws -> String

public typealias PrivilegedConfigTransport = @Sendable (
    _ config: Data,
    _ runtimeDirectory: URL,
    _ launch: @Sendable (URL) async throws -> Int32
) async throws -> Int32

public typealias PrivilegedProcessInspector = @Sendable (_ pid: Int32) async throws -> String?

typealias OSAScriptRunner = @Sendable (
    _ executable: URL,
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

enum OSAScriptAuthorizer {
    static func run(
        script: String,
        timeout: TimeInterval,
        runner: @escaping OSAScriptRunner = { executable, arguments, timeout in
            try await ProcessRunner.run(
                executable: executable,
                arguments: arguments,
                timeout: timeout
            )
        }
    ) async throws -> String {
        do {
            let result = try await runner(
                URL(fileURLWithPath: "/usr/bin/osascript"),
                ["-e", script],
                timeout
            )
            guard result.exitCode == 0 else {
                let message = authorizationMessage(from: result)
                if message.localizedCaseInsensitiveContains("cancel") || message.contains("-128") {
                    throw PrivilegedLauncherError.authorizationCancelled
                }
                throw PrivilegedLauncherError.authorizationFailed(
                    message.isEmpty ? "osascript 退出码 \(result.exitCode)" : message
                )
            }
            return result.stdout
        } catch ProcessRunnerError.timedOut {
            throw PrivilegedLauncherError.authorizationTimedOut
        } catch let error as PrivilegedLauncherError {
            throw error
        } catch {
            throw PrivilegedLauncherError.authorizationFailed(error.localizedDescription)
        }
    }

    private static func authorizationMessage(from result: ProcessResult) -> String {
        let error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !error.isEmpty { return error }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PrivilegedCommandBuilder {
    private static let prompt = "kongshan 需要管理员权限启动 TUN"

    public static func start(binaryURL: URL, fifoURL: URL, logURL: URL) -> String {
        let command = [
            "umask 077",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "/bin/cat \(shellQuote(fifoURL.path)) | \(shellQuote(binaryURL.path)) run -c /dev/stdin >> \(shellQuote(logURL.path)) 2>&1 & /bin/echo $!"
        ].joined(separator: "; ")
        return appleScript(command: command)
    }

    public static func stop(pid: Int32, binaryURL: URL) throws -> String {
        guard pid > 1 else {
            throw PrivilegedLauncherError.invalidPID(String(pid))
        }

        let command = [
            "umask 077",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "process=$(/bin/ps -p \(pid) -o command=)",
            "case \"$process\" in *\(shellQuote(binaryURL.standardizedFileURL.path))*) /bin/kill -INT \(pid) ;; *) /bin/echo 'kongshan: refusing to stop an unexpected process' >&2; exit 64 ;; esac"
        ].joined(separator: "; ")
        return appleScript(command: command)
    }

    public static func parsePID(_ output: String) throws -> Int32 {
        let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(value), pid > 1 else {
            throw PrivilegedLauncherError.invalidPID(value)
        }
        return pid
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScript(command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
    }
}

enum POSIXConfigPipe {
    static func send(
        _ data: Data,
        runtimeDirectory: URL,
        launch: @Sendable (URL) async throws -> Int32
    ) async throws -> Int32 {
        try prepareRuntimeDirectory(runtimeDirectory)

        let fifoURL = runtimeDirectory.appending(
            path: "config-\(UUID().uuidString).fifo",
            directoryHint: .notDirectory
        )
        guard mkfifo(fifoURL.path, mode_t(0o600)) == 0 else {
            throw posixError()
        }
        defer { unlink(fifoURL.path) }

        let descriptor = open(fifoURL.path, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { close(descriptor) }

        let pid = try await launch(fifoURL)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw posixError()
        }

        try await writeAll(data, to: descriptor)
        return pid
    }

    private static func prepareRuntimeDirectory(_ directory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        } catch {
            throw PrivilegedLauncherError.pipeFailed(error.localizedDescription)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try writeAllSynchronously(data, to: descriptor)
                })
            }
        }
    }

    private static func writeAllSynchronously(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else {
                    throw PrivilegedLauncherError.pipeFailed("管道写入未取得进展")
                }
                offset += count
            }
        }
    }

    private static func posixError() -> PrivilegedLauncherError {
        PrivilegedLauncherError.pipeFailed(String(cString: strerror(errno)))
    }
}

/// MVP 只通过固定 AppleScript 获取单次管理员授权。不在此暴露任意 root shell API；
/// 后续若需降低授权频率，应迁移到经签名校验的 SMAppService helper 或 Network Extension。
public protocol PrivilegedLaunching: Sendable {
    func start(config: Data) async throws -> PrivilegedProcessRecord
    func stop() async throws
    func recoverIfNeeded() async throws
}

public actor PrivilegedLauncher: PrivilegedLaunching {
    public nonisolated let recoveryURL: URL

    private let storage: Storage
    private let binaryURL: URL
    private let runtimeDirectory: URL
    private let logURL: URL
    private let authorizationTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private let authorizer: PrivilegedAuthorizer
    private let configTransport: PrivilegedConfigTransport
    private let processInspector: PrivilegedProcessInspector
    private var operationInProgress = false

    public init(
        storage: Storage = Storage(),
        binaryURL: URL,
        authorizationTimeout: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = Date.init,
        authorizer: PrivilegedAuthorizer? = nil,
        configTransport: PrivilegedConfigTransport? = nil,
        processInspector: PrivilegedProcessInspector? = nil
    ) {
        self.storage = storage
        self.binaryURL = binaryURL.standardizedFileURL.resolvingSymlinksInPath()
        self.authorizationTimeout = authorizationTimeout
        self.now = now
        self.authorizer = authorizer ?? { script, timeout in
            try await OSAScriptAuthorizer.run(script: script, timeout: timeout)
        }
        self.configTransport = configTransport ?? { data, runtimeDirectory, launch in
            try await POSIXConfigPipe.send(
                data,
                runtimeDirectory: runtimeDirectory,
                launch: launch
            )
        }
        self.processInspector = processInspector ?? { pid in
            try await PrivilegedLauncher.inspectProcess(pid: pid)
        }
        recoveryURL = storage.rootDirectory.appending(path: "tun-recovery.json")
        runtimeDirectory = storage.rootDirectory.appending(path: "runtime", directoryHint: .isDirectory)
        logURL = storage.rootDirectory
            .appending(path: "logs", directoryHint: .isDirectory)
            .appending(path: "sing-box-tun.log")
    }

    public func start(config: Data) async throws -> PrivilegedProcessRecord {
        try beginOperation()
        defer { operationInProgress = false }

        try await storage.prepare()
        try await reconcileRecoveryBeforeStart()

        let binaryURL = self.binaryURL
        let authorizer = self.authorizer
        let timeout = authorizationTimeout
        let pid: Int32
        do {
            pid = try await configTransport(config, runtimeDirectory) { fifoURL in
                let script = PrivilegedCommandBuilder.start(
                    binaryURL: binaryURL,
                    fifoURL: fifoURL,
                    logURL: self.logURL
                )
                let output = try await authorizer(script, timeout)
                return try PrivilegedCommandBuilder.parsePID(output)
            }
        } catch {
            try? removeRecoveryRecord()
            throw error
        }

        guard try await processMatches(pid: pid, expectedPath: binaryURL.path) else {
            try? removeRecoveryRecord()
            throw PrivilegedLauncherError.processMismatch(pid)
        }

        let record = PrivilegedProcessRecord(
            pid: pid,
            binaryPath: binaryURL.path,
            launchedAt: now()
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try await storage.writeAtomically(try encoder.encode(record), to: recoveryURL)
        } catch {
            try? await stopVerifiedProcess(record)
            try? removeRecoveryRecord()
            throw PrivilegedLauncherError.persistenceFailed(error.localizedDescription)
        }
        return record
    }

    public func stop() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await stopFromRecoveryRecord()
    }

    public func recoverIfNeeded() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await stopFromRecoveryRecord()
    }

    private func reconcileRecoveryBeforeStart() async throws {
        guard let record = try await readRecoveryRecord() else { return }
        guard record.pid > 1,
              record.binaryPath == binaryURL.path,
              try await processMatches(pid: record.pid, expectedPath: record.binaryPath) else {
            try removeRecoveryRecord()
            return
        }
        throw PrivilegedLauncherError.recoveryPending(record.pid)
    }

    private func stopFromRecoveryRecord() async throws {
        guard let record = try await readRecoveryRecord() else { return }
        guard record.pid > 1, record.binaryPath == binaryURL.path else {
            try removeRecoveryRecord()
            return
        }
        guard try await processMatches(pid: record.pid, expectedPath: record.binaryPath) else {
            try removeRecoveryRecord()
            return
        }

        try await stopVerifiedProcess(record)
        try removeRecoveryRecord()
    }

    private func stopVerifiedProcess(_ record: PrivilegedProcessRecord) async throws {
        let script = try PrivilegedCommandBuilder.stop(
            pid: record.pid,
            binaryURL: URL(fileURLWithPath: record.binaryPath)
        )
        _ = try await authorizer(script, authorizationTimeout)
    }

    private func processMatches(pid: Int32, expectedPath: String) async throws -> Bool {
        guard let command = try await processInspector(pid)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return false
        }
        return command == expectedPath || command.hasPrefix(expectedPath + " ")
    }

    private func readRecoveryRecord() async throws -> PrivilegedProcessRecord? {
        guard let data = try await storage.readIfPresent(from: recoveryURL) else { return nil }
        do {
            return try JSONDecoder().decode(PrivilegedProcessRecord.self, from: data)
        } catch {
            throw PrivilegedLauncherError.invalidRecoveryRecord(error.localizedDescription)
        }
    }

    private func removeRecoveryRecord() throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        try FileManager.default.removeItem(at: recoveryURL)
    }

    private func beginOperation() throws {
        guard !operationInProgress else { throw PrivilegedLauncherError.operationInProgress }
        operationInProgress = true
    }

    private nonisolated static func inspectProcess(pid: Int32) async throws -> String? {
        guard pid > 1 else { throw PrivilegedLauncherError.invalidPID(String(pid)) }
        do {
            let result = try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-p", String(pid), "-o", "command="],
                timeout: 5
            )
            if result.exitCode == 1 { return nil }
            guard result.exitCode == 0 else {
                let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw PrivilegedLauncherError.processInspectionFailed(
                    message.isEmpty ? "ps 退出码 \(result.exitCode)" : message
                )
            }
            let command = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return command.isEmpty ? nil : command
        } catch let error as PrivilegedLauncherError {
            throw error
        } catch {
            throw PrivilegedLauncherError.processInspectionFailed(error.localizedDescription)
        }
    }
}
