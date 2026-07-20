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
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if kill(processID, 0) == 0 { kill(processID, SIGKILL) }
        }
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
