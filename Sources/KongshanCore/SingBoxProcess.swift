import Darwin
import Foundation

public struct SingBoxLogLine: Sendable {
    public enum Stream: Sendable { case standardOutput, standardError }
    public let stream: Stream
    public let text: String
}

public actor SingBoxProcess {
    public typealias LogHandler = @Sendable (SingBoxLogLine) -> Void
    public typealias LogErrorHandler = @Sendable (String) -> Void
    public typealias UnexpectedExitHandler = @Sendable (Int32) -> Void

    private let binaryURL: URL
    private let logStore: KernelLogStore?
    private let logHandler: LogHandler
    private let logErrorHandler: LogErrorHandler
    private let unexpectedExitHandler: UnexpectedExitHandler
    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var stopping = false

    public init(
        binaryURL: URL,
        logStore: KernelLogStore? = nil,
        logHandler: @escaping LogHandler = { _ in },
        logErrorHandler: @escaping LogErrorHandler = { _ in },
        unexpectedExitHandler: @escaping UnexpectedExitHandler = { _ in }
    ) {
        self.binaryURL = binaryURL
        self.logStore = logStore
        self.logHandler = logHandler
        self.logErrorHandler = logErrorHandler
        self.unexpectedExitHandler = unexpectedExitHandler
    }

    public var isRunning: Bool { process?.isRunning == true }

    public var currentPID: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    public func check(config: Data, timeout: TimeInterval = 10) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: binaryURL,
            arguments: ["check", "-c", "/dev/stdin"],
            standardInput: config,
            timeout: timeout
        )
    }

    public func start(config: Data) throws {
        if let process {
            guard !process.isRunning else { return }
            clearStreams()
            self.process = nil
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["run", "-c", "/dev/stdin"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        stream(outputPipe, as: .standardOutput)
        stream(errorPipe, as: .standardError)
        process.terminationHandler = { [weak self] process in
            let processID = process.processIdentifier
            let exitCode = process.terminationStatus
            Task { await self?.didTerminate(processID: processID, exitCode: exitCode) }
        }

        try process.run()
        self.process = process
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        stopping = false

        try inputPipe.fileHandleForWriting.write(contentsOf: config)
        try inputPipe.fileHandleForWriting.close()
    }

    public func restart(config: Data) throws {
        stop()
        try start(config: config)
    }

    public func stop() {
        guard let process else { return }
        stopping = true
        let processID = process.processIdentifier
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if kill(processID, 0) == 0 { kill(processID, SIGTERM) }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.2) {
            if kill(processID, 0) == 0 { kill(processID, SIGKILL) }
        }
        process.waitUntilExit()
        clearStreams()
        self.process = nil
        stopping = false
    }

    private func stream(_ pipe: Pipe, as stream: SingBoxLogLine.Stream) {
        let handler = logHandler
        let store = logStore
        let errorHandler = logErrorHandler
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let line = SingBoxLogLine(stream: stream, text: String(decoding: data, as: UTF8.self))
            handler(line)
            if let store {
                Task {
                    do {
                        try await store.append(line)
                    } catch {
                        errorHandler(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func didTerminate(processID: Int32, exitCode: Int32) {
        guard process?.processIdentifier == processID else { return }
        let wasUnexpected = !stopping
        clearStreams()
        process = nil
        if wasUnexpected { unexpectedExitHandler(exitCode) }
    }

    private func clearStreams() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
    }
}
