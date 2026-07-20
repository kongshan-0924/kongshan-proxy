import Darwin
import Dispatch
import Foundation

public protocol ProcessExitMonitoring: Sendable {
    func monitor(
        pid: Int32,
        handler: @escaping @Sendable (Int32) -> Void
    ) async throws
    func cancel() async
}

public enum ProcessExitMonitorError: Error, Equatable, LocalizedError {
    case invalidPID(Int32)
    case processNotRunning(Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidPID(pid):
            "无法监控无效进程 PID：\(pid)"
        case let .processNotRunning(pid):
            "无法监控未运行的进程 PID：\(pid)"
        }
    }
}

public actor ProcessExitMonitor: ProcessExitMonitoring {
    private var source: (any DispatchSourceProcess)?

    public init() {}

    deinit {
        source?.setEventHandler {}
        source?.cancel()
    }

    public func monitor(
        pid: Int32,
        handler: @escaping @Sendable (Int32) -> Void
    ) throws {
        guard pid > 1 else { throw ProcessExitMonitorError.invalidPID(pid) }
        guard Darwin.kill(pid, 0) == 0 || errno == EPERM else {
            throw ProcessExitMonitorError.processNotRunning(pid)
        }

        cancel()
        let source = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            handler(pid)
        }
        self.source = source
        source.resume()
    }

    public func cancel() {
        source?.setEventHandler {}
        source?.cancel()
        source = nil
    }
}
