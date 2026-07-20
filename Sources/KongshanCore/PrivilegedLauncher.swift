import Darwin
import Foundation

public enum PrivilegedLauncherError: Error, Equatable, LocalizedError {
    case invalidPID(String)
    case pipeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPID(value):
            "管理员进程返回了无效 PID：\(value)"
        case let .pipeFailed(message):
            "无法安全传递 TUN 配置：\(message)"
        }
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
