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
    /// 日志块的单一消费者入口，见 `startLogDrain`。
    private var logContinuation: AsyncStream<SingBoxLogLine>.Continuation?
    private var logDrainTask: Task<Void, Never>?
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

        startLogDrain()
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

    public func restart(config: Data) async throws {
        await stop()
        try start(config: config)
    }

    /// 停止内核。把 waitUntilExit 放到 Task.detached 里 await，避免阻塞 actor mailbox。
    /// 旧实现里 waitUntilExit 同步阻塞，若 sing-box 不响应 SIGINT，
    /// actor 会阻塞 2.2 秒（到 SIGKILL），期间 isRunning/currentPID/restart 等全部排队，
    /// 崩溃自愈路径里这会拖长恢复时间。
    public func stop() async {
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
        await Task.detached { [process] in process.waitUntilExit() }.value
        clearStreams()
        // 等这一代的日志收尾（尾行、折叠总结）写完再返回：「先停再启」时下一代的日志
        // 才不会和上一代的收尾交错。
        await logDrainTask?.value
        logDrainTask = nil
        self.process = nil
        stopping = false
    }

    /// 日志块交给**单一消费者**按到达顺序落盘。
    ///
    /// 旧实现每块日志各开一个 `Task` 去调 actor，而 actor 不保证这些调用按创建顺序执行。
    /// 日志存储现在要把块拼成整行再折叠刷屏（`KernelLogFolder`），块一乱序就会把两行拼坏。
    /// 流结束（内核退出、`clearStreams`）时让存储写出尾行与折叠总结。
    private func startLogDrain() {
        logContinuation?.finish()
        logContinuation = nil
        guard let store = logStore else { return }
        let errorHandler = logErrorHandler
        let (lines, continuation) = AsyncStream.makeStream(of: SingBoxLogLine.self)
        logContinuation = continuation
        logDrainTask = Task {
            for await line in lines {
                do {
                    try await store.append(line)
                } catch {
                    errorHandler(error.localizedDescription)
                }
            }
            do {
                try await store.finish(source: .system)
            } catch {
                errorHandler(error.localizedDescription)
            }
        }
    }

    private func stream(_ pipe: Pipe, as stream: SingBoxLogLine.Stream) {
        let handler = logHandler
        let continuation = logContinuation
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let line = SingBoxLogLine(stream: stream, text: String(decoding: data, as: UTF8.self))
            handler(line)
            continuation?.yield(line)
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
        logContinuation?.finish()
        logContinuation = nil
    }
}
