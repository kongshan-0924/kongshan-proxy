import Darwin
import Foundation

public struct ProcessResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum ProcessRunnerError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(message): "无法启动子进程：\(message)"
        case .timedOut: "子进程执行超时"
        }
    }
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String] = [],
        standardInput: Data? = nil,
        timeout: TimeInterval
    ) async throws -> ProcessResult {
        let execution = ProcessExecution(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput,
            timeout: timeout
        )
        return try await execution.run()
    }
}

private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let standardInput: Data?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var completed = false
    private var continuation: CheckedContinuation<ProcessResult, Error>?

    init(executable: URL, arguments: [String], standardInput: Data?, timeout: TimeInterval) {
        self.standardInput = standardInput
        self.timeout = timeout
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // 强制子进程用英文 locale：networksetup 在中文系统下会把"无 bypass domains"
        // 之类的提示本地化成中文，导致 SystemProxyCommands.bypassDomains 与
        // SystemDNSCommands.servers 的英文文案匹配失败，把中文提示当成域名/服务器写回系统。
        // LANG/LC_ALL=en_US.UTF-8 让 networksetup 等工具稳定输出英文。
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        process.environment = env
    }

    func run() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            process.terminationHandler = { [weak self] process in
                self?.processTerminated(exitCode: process.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                complete(.failure(ProcessRunnerError.launchFailed(error.localizedDescription)))
                return
            }

            if let standardInput {
                try? inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
            }
            try? inputPipe.fileHandleForWriting.close()

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.timeOut()
            }
        }
    }

    private func processTerminated(exitCode: Int32) {
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        complete(.success(ProcessResult(
            exitCode: exitCode,
            stdout: String(decoding: output, as: UTF8.self),
            stderr: String(decoding: error, as: UTF8.self)
        )))
    }

    private func timeOut() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        let processID = process.processIdentifier
        continuation?.resume(throwing: ProcessRunnerError.timedOut)
        // 超时路径下子进程已不可信任（死循环 / hang 住），SIGTERM 的优雅清理窗口无意义。
        // 直接 SIGKILL 立即回收，省掉旧实现的 0.2s asyncAfter 等待。
        // process.terminate() 内部也是发 SIGTERM，超时场景下多半无效，这里直接走 SIGKILL。
        if kill(processID, 0) == 0 { kill(processID, SIGKILL) }
    }

    private func complete(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
