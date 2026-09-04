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

/// 一次 `/connections` 推送的完整内容：总量快照 + 每条连接的明细。
/// 两者来自同一份 payload，**只解析一次**（见 `connectionFeedStream`）。
public struct ConnectionFeed: Equatable, Sendable {
    public let snapshot: ConnectionSnapshot
    public let details: [ConnectionDetail]

    public init(snapshot: ConnectionSnapshot, details: [ConnectionDetail]) {
        self.snapshot = snapshot
        self.details = details
    }
}

public struct ConnectionSnapshot: Equatable, Sendable {
    public let connectionCount: Int
    public let memory: UInt64
    /// 内核自启动以来的累计字节数（`/connections` 的 `uploadTotal`/`downloadTotal`）。
    ///
    /// 这是**唯一权威的累计量**。不能靠把 `/traffic` 的速率乘以采样间隔来估——
    /// 那会漏掉两次采样之间开完又关掉的连接，也会被采样抖动放大误差；
    /// 同样不能靠累加每条活跃连接的 upload/download，短命连接同样统计不到。
    public let uploadTotal: Int64
    public let downloadTotal: Int64

    public init(connectionCount: Int, memory: UInt64, uploadTotal: Int64 = 0, downloadTotal: Int64 = 0) {
        self.connectionCount = connectionCount
        self.memory = memory
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
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
    /// 连接建立时间（`/connections` 每项的 `start`，ISO8601）。
    ///
    /// 用来算**首次采样**的速率：速率原本靠相邻两次采样的字节差，于是每条连接第一次
    /// 出现时只能显示 `—`。短命连接（一次请求就关）往往只被采样到一次，
    /// 结果是明明在传数据、界面上却始终是 `—`，看起来像统计坏了。
    public let start: Date?

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
        start = (payload["start"] as? String).flatMap(Self.isoFormatter.date(from:))
    }

    /// 内核给的是带小数秒的 ISO8601（`2026-07-30T12:00:00.123456789+08:00`）。
    /// `.withInternetDateTime` 单独用会因为小数秒解析失败，必须并上 `.withFractionalSeconds`。
    /// `nonisolated(unsafe)`：Foundation 的 formatter 在**构造完成后不再修改**的前提下是
    /// 线程安全的（Apple 文档明确写了这一点），这里正是只读使用。
    /// 不能改成每次解析新建一个：连接页每秒解析上千条，那是实打实的开销。
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public struct ConnectionEndpoint: Equatable, Sendable {
    public let address: String
    public let port: Int?
    public let isIPAddress: Bool

    public init(address: String, port: Int?, isIPAddress: Bool) {
        self.address = address
        self.port = port
        self.isIPAddress = isIPAddress
    }

    public init(hostAndPort: String) {
        let raw = hostAndPort.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = raw
        var port: Int?
        if raw.hasPrefix("["), let closing = raw.firstIndex(of: "]") {
            address = String(raw[raw.index(after: raw.startIndex)..<closing])
            let suffix = raw[raw.index(after: closing)...]
            if suffix.first == ":" { port = Int(suffix.dropFirst()) }
        } else if let colon = raw.lastIndex(of: ":"),
                  let parsedPort = Int(raw[raw.index(after: colon)...]),
                  (0...65_535).contains(parsedPort) {
            address = String(raw[..<colon])
            port = parsedPort
        }
        self.address = address
        self.port = port
        isIPAddress = CustomRouteRule.normalizedCIDR(address) != nil
    }

    public var displayValue: String { address }
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
                memory: memory.uint64Value,
                uploadTotal: (payload["uploadTotal"] as? NSNumber)?.int64Value ?? 0,
                downloadTotal: (payload["downloadTotal"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    /// 连接详情的 WebSocket 推送流。监控页用它替代 1.5s 轮询：
    /// 推送由内核按 `interval` 主动发，省掉客户端的轮询请求 + 减少 UI 抖动。
    ///
    /// **同时回传总量快照**，因为它和 `connectionStream()` 订阅的是同一个 `/connections` 端点、
    /// 收到的是同一份 payload。两条流各跑一遍 `JSONSerialization` 就是把 120~160 条连接的
    /// JSON 每秒解析两次：真机 2026-09-04 连接页开着时 CPU 均值 3~7.7%、主线程只占 48%
    /// ——另一半正是这份重复解析。合流后连接页开着时只有一条订阅。
    public func connectionFeedStream(intervalMilliseconds: Int = 1000) -> AsyncThrowingStream<ConnectionFeed, Error> {
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
            let details = connections.map(ConnectionDetail.init(payload:))
            return ConnectionFeed(
                snapshot: ConnectionSnapshot(
                    connectionCount: details.count,
                    memory: (payload["memory"] as? NSNumber)?.uint64Value ?? 0,
                    uploadTotal: (payload["uploadTotal"] as? NSNumber)?.int64Value ?? 0,
                    downloadTotal: (payload["downloadTotal"] as? NSNumber)?.int64Value ?? 0
                ),
                details: details
            )
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
