import Foundation

public enum ClashAPIError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Clash API 返回了无效响应"
        case let .httpStatus(code): "Clash API 返回 HTTP \(code)"
        case .invalidPayload: "Clash API 返回的数据格式无效"
        }
    }
}

public enum DelayResult: Equatable, Sendable {
    case success(Int)
    case failure(String)
}

public struct TrafficSample: Codable, Equatable, Sendable {
    public let up: Int64
    public let down: Int64

    public init(up: Int64, down: Int64) {
        self.up = up
        self.down = down
    }
}

public struct ConnectionSnapshot: Equatable, Sendable {
    public let connectionCount: Int
    public let memory: UInt64

    public init(connectionCount: Int, memory: UInt64) {
        self.connectionCount = connectionCount
        self.memory = memory
    }
}

/// 一条活跃连接的详情（GET /connections 里的一项），供监控页展示。
public struct ConnectionDetail: Identifiable, Equatable, Sendable {
    public let id: String
    public let host: String          // 目标主机（域名优先，回退 IP:端口）
    public let process: String?      // 发起进程名（内核 sniff 到才有）
    public let rule: String          // 命中的规则（含 payload）
    public let chains: [String]      // 出站链路，从入站到最终节点
    public let network: String       // tcp / udp
    public let upload: Int64
    public let download: Int64

    public init(payload: [String: Any]) {
        id = payload["id"] as? String ?? UUID().uuidString
        let meta = payload["metadata"] as? [String: Any] ?? [:]
        let hostName = (meta["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let destIP = meta["destinationIP"] as? String ?? ""
        let destPort = meta["destinationPort"] as? String ?? (meta["destinationPort"] as? NSNumber).map { "\($0)" } ?? ""
        host = hostName.map { destPort.isEmpty ? $0 : "\($0):\(destPort)" }
            ?? (destPort.isEmpty ? destIP : "\(destIP):\(destPort)")
        let proc = (meta["process"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        process = proc
        network = (meta["network"] as? String) ?? "tcp"
        let ruleName = payload["rule"] as? String ?? ""
        let rulePayload = (payload["rulePayload"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        rule = rulePayload.map { "\(ruleName) : \($0)" } ?? ruleName
        // chains 内核给的是「最终→入站」倒序，反转成「入站→最终」更符合直觉
        chains = ((payload["chains"] as? [String]) ?? []).reversed()
        upload = (payload["upload"] as? NSNumber)?.int64Value ?? 0
        download = (payload["download"] as? NSNumber)?.int64Value ?? 0
    }
}

public enum CoreLogLevel: String, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error

    var apiValue: String {
        self == .warning ? "warn" : rawValue
    }

    init?(apiValue: String) {
        switch apiValue.lowercased() {
        case "debug", "trace": self = .debug
        case "info": self = .info
        case "warn", "warning": self = .warning
        case "error", "fatal", "panic": self = .error
        default: return nil
        }
    }
}

public struct CoreLogEntry: Equatable, Sendable {
    public let level: CoreLogLevel
    public let message: String
    public let receivedAt: Date

    public init(level: CoreLogLevel, message: String, receivedAt: Date) {
        self.level = level
        self.message = message
        self.receivedAt = receivedAt
    }
}

public typealias ClashDataStreamFactory = @Sendable (
    _ request: URLRequest
) -> AsyncThrowingStream<Data, Error>

public actor ClashAPIClient {
    private let controller: URL
    private let secret: String
    private let session: URLSession
    private let streamFactory: ClashDataStreamFactory
    private let now: @Sendable () -> Date

    public init(
        controller: URL,
        secret: String,
        session: URLSession = .shared,
        streamFactory: ClashDataStreamFactory? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.controller = controller
        self.secret = secret
        self.session = session
        self.streamFactory = streamFactory ?? { request in
            Self.webSocketDataStream(session: session, request: request)
        }
        self.now = now
    }

    public func health() async throws {
        _ = try await version()
    }

    public func version() async throws -> String {
        let (data, _) = try await perform(request(path: ["version"]))
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = payload["version"] as? String else {
            throw ClashAPIError.invalidPayload
        }
        return version
    }

    public func select(node: String, in group: String = "手动选择") async throws {
        var request = request(path: ["proxies", group])
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": node], options: [.sortedKeys])
        _ = try await perform(request)
    }

    /// 关闭全部活跃连接（DELETE /connections）。切换节点后调用，逼现有 keep-alive 连接重连，
    /// 让新节点立刻生效（否则浏览器复用旧连接，出口 IP 不变）。
    public func closeAllConnections() async throws {
        var request = request(path: ["connections"])
        request.httpMethod = "DELETE"
        _ = try await perform(request)
    }

    /// 关闭单条连接（DELETE /connections/{id}）。
    public func closeConnection(id: String) async throws {
        var request = request(path: ["connections", id])
        request.httpMethod = "DELETE"
        _ = try await perform(request)
    }

    /// 拉一次连接详情快照（GET /connections）。监控页用它列出每条连接。
    public func connectionsSnapshot() async throws -> [ConnectionDetail] {
        let (data, _) = try await perform(request(path: ["connections"]))
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawConnections = payload["connections"] as? [[String: Any]] else {
            return []
        }
        return rawConnections.map(ConnectionDetail.init(payload:))
    }

    public nonisolated func delay(
        node: String,
        testURL: URL,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Int {
        let endpoint = url(path: ["proxies", node, "delay"])
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ClashAPIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: testURL.absoluteString),
            URLQueryItem(name: "timeout", value: String(timeoutMilliseconds))
        ]
        guard let url = components.url else { throw ClashAPIError.invalidResponse }
        var request = authenticatedRequest(url: url)
        request.timeoutInterval = TimeInterval(timeoutMilliseconds) / 1_000

        let (data, _) = try await perform(request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delay = payload["delay"] as? Int else {
            throw ClashAPIError.invalidPayload
        }
        return delay
    }

    public func delays(
        nodes: [String],
        testURL: URL,
        limit: Int = 8
    ) async -> [String: DelayResult] {
        let limit = max(1, min(limit, 8))
        var results: [String: DelayResult] = [:]
        var start = 0
        while start < nodes.count {
            let end = min(start + limit, nodes.count)
            let batch = Array(nodes[start..<end])
            // delay 是 nonisolated，子任务可以真正并发执行 URLSession 请求，
            // 不会被 actor mailbox 串行化（旧实现里 delay 是 actor 方法，
            // limit=8 的"并发"实际退化成 8 个请求并发但响应处理排队）。
            await withTaskGroup(of: (String, DelayResult).self) { group in
                for node in batch {
                    group.addTask { [self] in
                        do {
                            return (node, .success(try await delay(node: node, testURL: testURL)))
                        } catch {
                            return (node, .failure(error.localizedDescription))
                        }
                    }
                }
                for await (node, result) in group { results[node] = result }
            }
            start = end
        }
        return results
    }

    public func trafficStream() -> AsyncThrowingStream<TrafficSample, Error> {
        guard let request = webSocketRequest(path: ["traffic"]) else {
            return failedStream(ClashAPIError.invalidResponse)
        }
        return decodeStream(request) { data in
            try JSONDecoder().decode(TrafficSample.self, from: data)
        }
    }

    public func connectionStream() -> AsyncThrowingStream<ConnectionSnapshot, Error> {
        guard let request = webSocketRequest(
            path: ["connections"],
            queryItems: [URLQueryItem(name: "interval", value: "1000")]
        ) else {
            return failedStream(ClashAPIError.invalidResponse)
        }
        return decodeStream(request) { data in
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = payload["connections"] as? [Any],
                  let memory = payload["memory"] as? NSNumber else {
                throw ClashAPIError.invalidPayload
            }
            return ConnectionSnapshot(
                connectionCount: connections.count,
                memory: memory.uint64Value
            )
        }
    }

    /// 连接详情的 WebSocket 推送流。监控页用它替代 1.5s 轮询：
    /// 推送由内核按 `interval` 主动发，省掉客户端的轮询请求 + 减少 UI 抖动。
    public func connectionDetailsStream(intervalMilliseconds: Int = 1000) -> AsyncThrowingStream<[ConnectionDetail], Error> {
        guard let request = webSocketRequest(
            path: ["connections"],
            queryItems: [URLQueryItem(name: "interval", value: String(intervalMilliseconds))]
        ) else {
            return failedStream(ClashAPIError.invalidResponse)
        }
        return decodeStream(request) { data in
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let connections = payload["connections"] as? [[String: Any]] else {
                throw ClashAPIError.invalidPayload
            }
            return connections.map(ConnectionDetail.init(payload:))
        }
    }

    public func logStream(level: CoreLogLevel) -> AsyncThrowingStream<CoreLogEntry, Error> {
        guard let request = webSocketRequest(
            path: ["logs"],
            queryItems: [URLQueryItem(name: "level", value: level.apiValue)]
        ) else {
            return failedStream(ClashAPIError.invalidResponse)
        }
        let now = self.now
        return decodeStream(request) { data in
            let payload = try JSONDecoder().decode(LogPayload.self, from: data)
            guard let level = CoreLogLevel(apiValue: payload.type) else {
                throw ClashAPIError.invalidPayload
            }
            return CoreLogEntry(level: level, message: payload.payload, receivedAt: now())
        }
    }

    private nonisolated func request(path: [String]) -> URLRequest {
        authenticatedRequest(url: url(path: path))
    }

    private nonisolated func url(path: [String]) -> URL {
        path.reduce(controller) { partial, component in partial.appending(path: component) }
    }

    private nonisolated func webSocketRequest(
        path: [String],
        queryItems: [URLQueryItem] = []
    ) -> URLRequest? {
        guard var components = URLComponents(
            url: url(path: path),
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { return nil }
        return authenticatedRequest(url: url)
    }

    private func decodeStream<Output: Sendable>(
        _ request: URLRequest,
        transform: @escaping @Sendable (Data) throws -> Output
    ) -> AsyncThrowingStream<Output, Error> {
        let source = streamFactory(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in source {
                        do {
                            continuation.yield(try transform(data))
                        } catch {
                            continuation.finish(throwing: ClashAPIError.invalidPayload)
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func failedStream<Output: Sendable>(
        _ error: Error
    ) -> AsyncThrowingStream<Output, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: error)
        }
    }

    private nonisolated func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private nonisolated func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClashAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ClashAPIError.httpStatus(http.statusCode)
        }
        return (data, http)
    }

    private nonisolated static func webSocketDataStream(
        session: URLSession,
        request: URLRequest
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let socket = session.webSocketTask(with: request)
            let receiveTask = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        switch message {
                        case let .data(data):
                            continuation.yield(data)
                        case let .string(text):
                            continuation.yield(Data(text.utf8))
                        @unknown default:
                            continuation.finish(throwing: ClashAPIError.invalidPayload)
                            socket.cancel(with: .goingAway, reason: nil)
                            return
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                    // 错误路径也要显式 cancel socket：onTermination 只在 consumer 终止流时触发，
                    // 若 consumer 已停止迭代但未显式 finish（如 AsyncThrowingStream 被丢弃），
                    // socket 会滞留。这里幂等地 cancel 一下，确保资源释放。
                    socket.cancel(with: .goingAway, reason: nil)
                }
            }
            continuation.onTermination = { @Sendable _ in
                receiveTask.cancel()
                socket.cancel(with: .goingAway, reason: nil)
            }
            socket.resume()
        }
    }
}

private struct LogPayload: Decodable {
    let type: String
    let payload: String
}
