import Foundation
import Network
import XCTest
@testable import KongshanCore

/// 中转层并发吞吐的测量（**不是断言性测试**，只在设了 KONGSHAN_RELAY_BENCH 时跑）。
///
/// 目的：验证「所有中转连接共用一条串行 DispatchQueue」是否构成并发瓶颈。
/// 系统代理模式下浏览器与 Codex 的每一条连接都要过这里，若并发一上来单条吞吐就塌，
/// 用户感受到的就是"日常上网卡"。
final class RelayThroughputBenchmark: XCTestCase {
    func testAggregateThroughputAcrossConcurrency() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KONGSHAN_RELAY_BENCH"] == nil)

        // 单条 4 MB：小于内核缓冲区的量会被缓冲吸收，测不出转发本身的代价。
        let payloadBytes = 4 * 1024 * 1024
        let sink = try LocalSink(expectedBytes: payloadBytes)
        let backendPort = try sink.start()
        defer { sink.stop() }

        let relay = LocalTCPRelay()
        let relayPort = try await relay.start(preferredPort: nil)
        relay.setTarget(port: backendPort)
        defer { relay.stop() }

        let payload = Data(repeating: 0x41, count: payloadBytes)
        for concurrency in [1, 4, 16, 48] {
            let began = ContinuousClock.now
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<concurrency {
                    group.addTask { await Self.push(payload, to: relayPort) }
                }
                for await _ in group {}
            }
            let elapsed = began.duration(to: .now)
            let ms = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1e15
            let totalMB = Double(concurrency) * Double(payloadBytes) / 1_048_576.0
            print(String(
                format: "  并发 %2d：总计 %.2f MB，用时 %6.0f ms，聚合 %6.1f MB/s，单条 %5.1f MB/s",
                concurrency, totalMB, ms, totalMB / (ms / 1000), totalMB / (ms / 1000) / Double(concurrency)
            ))
        }
    }

    private static func push(_ payload: Data, to port: UInt16) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            let gate = FinishOnce(connection: connection, continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 先挂上接收：接收端收满整份 payload 后会回 1 字节，收到它才算真正转发完。
                    // 只等 send 完成是不行的——那只代表数据进了内核缓冲区。
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                        gate.finish()
                    }
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                case .failed, .cancelled:
                    gate.finish()
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "bench.client"))
        }
    }
}

/// 只读不回的本地接收端，扮演 sing-box 的 mixed inbound。
private final class LocalSink: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "bench.sink", attributes: .concurrent)
    private let expectedBytes: Int

    init(expectedBytes: Int) throws {
        self.expectedBytes = expectedBytes
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() throws -> UInt16 {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        let expected = self.expectedBytes
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            let counter = ByteCounter()
            func drain() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let data, !data.isEmpty, counter.add(data.count) >= expected {
                        // 收满整份就回 1 字节，客户端据此判定端到端完成。
                        connection.send(content: Data([0x06]), completion: .contentProcessed { _ in })
                        return
                    }
                    if complete || error != nil { connection.cancel() } else { drain() }
                }
            }
            drain()
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else { throw BenchError.noPort }
        return port
    }

    func stop() { listener.cancel() }
}

private enum BenchError: Error { case noPort }

/// 只让第一次完成生效——send 完成与状态回调都可能先到。
private final class FinishOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let connection: NWConnection
    private let continuation: CheckedContinuation<Void, Never>

    init(connection: NWConnection, continuation: CheckedContinuation<Void, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish() {
        let first = lock.withLock { () -> Bool in
            guard !done else { return false }
            done = true
            return true
        }
        guard first else { return }
        connection.cancel()
        continuation.resume()
    }
}


/// 线程安全的累加器。
private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0

    func add(_ count: Int) -> Int {
        lock.withLock {
            total += count
            return total
        }
    }
}
