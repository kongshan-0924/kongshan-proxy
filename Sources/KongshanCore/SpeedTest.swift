import Foundation
import Network
import os

/// 测速方式。
public enum SpeedTestMethod: String, Codable, CaseIterable, Sendable {
    /// 直连节点 server:port 做 TCP 握手计时。快、稳、不需要内核在跑，
    /// 但只验证服务器可达，不验证代理链路。默认。
    case tcpPing
    /// 经 Clash API 让内核用当前代理请求测试 URL，测真实链路延迟。需要内核在跑。
    case urlTest

    public var displayName: String {
        switch self {
        case .tcpPing: "TCP 握手（快，直连）"
        case .urlTest: "URL 测速（经代理）"
        }
    }
}

/// 直连 TCP 握手测速。用 Network 框架连到 host:port，测到 `.ready` 的耗时。
public enum TCPPinger {
    public static func ping(
        host: String,
        port: Int,
        timeoutMilliseconds: Int = 3_000
    ) async -> DelayResult {
        guard (1...65_535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return .failure("端口无效")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "kongshan.tcpping")
        let start = DispatchTime.now()
        let finished = OSAllocatedUnfairLock(initialState: false)

        return await withCheckedContinuation { (continuation: CheckedContinuation<DelayResult, Never>) in
            @Sendable func finish(_ result: DelayResult) {
                let first = finished.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                    finish(.success(Int(ns / 1_000_000)))
                case let .failed(error):
                    finish(.failure(error.localizedDescription))
                case let .waiting(error):
                    // 拒绝 / 无路由会进入 waiting 反复重试，直接判失败，别一直挂着。
                    finish(.failure(error.localizedDescription))
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) {
                finish(.failure("超时"))
            }
            connection.start(queue: queue)
        }
    }

    /// 批量握手，限并发。TCP 握手很轻，并发可比 URL 测速高。
    public static func pingAll(
        targets: [(id: UUID, host: String, port: Int)],
        timeoutMilliseconds: Int = 3_000,
        concurrency: Int = 16
    ) async -> [UUID: DelayResult] {
        let limit = max(1, min(concurrency, 32))
        var results: [UUID: DelayResult] = [:]
        var start = 0
        while start < targets.count {
            let end = min(start + limit, targets.count)
            let batch = Array(targets[start..<end])
            await withTaskGroup(of: (UUID, DelayResult).self) { group in
                for target in batch {
                    group.addTask {
                        (target.id, await ping(
                            host: target.host,
                            port: target.port,
                            timeoutMilliseconds: timeoutMilliseconds
                        ))
                    }
                }
                for await (id, result) in group { results[id] = result }
            }
            start = end
        }
        return results
    }
}
