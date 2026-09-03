import Foundation
import HelperProtocol
import Network

public enum LocalTCPRelayError: Error, LocalizedError {
    case invalidPort(UInt16)
    case listenerFailed(String)
    case listenerCancelled

    public var errorDescription: String? {
        switch self {
        case let .invalidPort(port): "无效的本地转发端口：\(port)"
        case let .listenerFailed(message): "本地代理入口启动失败：\(message)"
        case .listenerCancelled: "本地代理入口在启动完成前已停止"
        }
    }
}

public protocol LocalTCPRelaying: AnyObject, Sendable {
    func start(preferredPort: UInt16?) async throws -> UInt16
    func setTarget(port: UInt16?)
    /// 另起一个监听全部接口的入口，供局域网设备使用。返回实际绑定的端口。
    func startLANSharing(preferredPort: UInt16?, policy: LANPeerPolicy) async throws -> UInt16
    func stopLANSharing()
    /// 局域网客户端的累计用量。断开的客户端仍保留，直到共享关闭。
    func lanClients() -> [LANClientStats]
    func stop()
}

/// App 持有的稳定 TCP 入口。它只转发原始字节，不解析 HTTP CONNECT 或 SOCKS。
/// 系统代理始终指向这里；sing-box 的 mixed inbound 则使用每代独立的内部端口。
///
/// **局域网共享也落在这一层，不动内核**：`HelperConfigWhitelist` 强制内核的 mixed 入站
/// 只能听 loopback（root 进程不该对外开代理端口），那条边界不碰。中转层跑在用户权限下，
/// 由它多听一个网络接口是安全得多的做法。
public final class LocalTCPRelay: LocalTCPRelaying, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kaysen.kongshan.local-tcp-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var targetPort: UInt16?
    private var pairs: [UUID: RelayPair] = [:]

    /// 局域网入口是**独立的监听与端口**，不是把本机入口改绑到 0.0.0.0。
    /// 这样开关共享完全不碰系统代理走的那条 loopback 监听——上一版同端口重绑的做法
    /// 每次切换都会掐断所有正在走代理的连接。
    private var lanListener: NWListener?
    private var lanPort: UInt16?
    private var lanPolicy = LANPeerPolicy()
    private var lanStats: [String: MutableClientStats] = [:]

    /// 客户端条目上限。断开后仍保留是为了让用户看到"刚才谁用过"，
    /// 但不能无上限——超出时淘汰最久未活动的。
    private static let maxTrackedClients = 200

    private struct MutableClientStats {
        var activeConnections = 0
        var upload: Int64 = 0
        var download: Int64 = 0
        var firstSeenAt: Date
        var lastActiveAt: Date
    }

    public init() {}

    deinit {
        stop()
    }

    public func start(preferredPort: UInt16?) async throws -> UInt16 {
        if let existing = lock.withLock({ boundPort }) { return existing }

        let port = try await RuntimeSecrets.stableHighPort(preferred: preferredPort)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalTCPRelayError.invalidPort(port)
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(HelperConstants.loopbackAddress),
            port: nwPort
        )
        let candidate = try NWListener(using: parameters)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = StartGate(continuation: continuation)
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate else {
                    gate.fail(LocalTCPRelayError.listenerCancelled)
                    return
                }
                switch state {
                case .ready:
                    self.lock.withLock {
                        self.listener = candidate
                        self.boundPort = port
                    }
                    gate.succeed(port)
                case let .failed(error):
                    candidate.cancel()
                    gate.fail(LocalTCPRelayError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    gate.fail(LocalTCPRelayError.listenerCancelled)
                default:
                    break
                }
            }
            candidate.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, fromLAN: false)
            }
            candidate.start(queue: queue)
        }
    }

    public func startLANSharing(preferredPort: UInt16?, policy: LANPeerPolicy) async throws -> UInt16 {
        if let existing = lock.withLock({ lanPort }) { return existing }

        let port = try await RuntimeSecrets.stableHighPort(preferred: preferredPort)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalTCPRelayError.invalidPort(port)
        }
        lock.withLock { self.lanPolicy = policy }

        // 不设 requiredLocalEndpoint 即监听全部接口。来源限制在 accept 里做，
        // 而不是靠绑定地址——绑定粒度到不了"只允许某几个网段"。
        let candidate = try NWListener(using: .tcp, on: nwPort)

        return try await withCheckedThrowingContinuation { continuation in
            let gate = StartGate(continuation: continuation)
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let self, let candidate else {
                    gate.fail(LocalTCPRelayError.listenerCancelled)
                    return
                }
                switch state {
                case .ready:
                    self.lock.withLock {
                        self.lanListener = candidate
                        self.lanPort = port
                    }
                    gate.succeed(port)
                case let .failed(error):
                    candidate.cancel()
                    gate.fail(LocalTCPRelayError.listenerFailed(error.localizedDescription))
                case .cancelled:
                    gate.fail(LocalTCPRelayError.listenerCancelled)
                default:
                    break
                }
            }
            candidate.newConnectionHandler = { [weak self] connection in
                self?.accept(connection, fromLAN: true)
            }
            candidate.start(queue: queue)
        }
    }

    public func stopLANSharing() {
        let snapshot: (NWListener?, [RelayPair]) = lock.withLock {
            let listener = lanListener
            let lanPairs = pairs.values.filter(\.isFromLAN)
            lanListener = nil
            lanPort = nil
            lanStats.removeAll()
            return (listener, Array(lanPairs))
        }
        snapshot.0?.cancel()
        // 只掐局域网来的连接，本机走系统代理的那些不受影响。
        snapshot.1.forEach { $0.cancel() }
    }

    public func lanClients() -> [LANClientStats] {
        lock.withLock {
            lanStats.map { address, value in
                LANClientStats(
                    address: address,
                    activeConnections: value.activeConnections,
                    upload: value.upload,
                    download: value.download,
                    firstSeenAt: value.firstSeenAt,
                    lastActiveAt: value.lastActiveAt
                )
            }
        }
        .sorted { $0.total > $1.total }
    }

    public func setTarget(port: UInt16?) {
        let stalePairs: [RelayPair] = lock.withLock {
            guard targetPort != port else { return [] }
            targetPort = port
            let values = Array(pairs.values)
            pairs.removeAll(keepingCapacity: true)
            return values
        }
        stalePairs.forEach { $0.cancel() }
    }

    public func stop() {
        let snapshot: ([NWListener], [RelayPair]) = lock.withLock {
            let listeners = [listener, lanListener].compactMap { $0 }
            let result = (listeners, Array(pairs.values))
            listener = nil
            lanListener = nil
            boundPort = nil
            lanPort = nil
            targetPort = nil
            lanStats.removeAll()
            pairs.removeAll(keepingCapacity: false)
            return result
        }
        snapshot.0.forEach { $0.cancel() }
        snapshot.1.forEach { $0.cancel() }
    }

    private func accept(_ client: NWConnection, fromLAN: Bool) {
        let pair: RelayPair? = lock.withLock {
            guard let targetPort,
                  let nwPort = NWEndpoint.Port(rawValue: targetPort) else { return nil }
            // 局域网入口的来源限制。基线是"必须私网"，白名单在此之上再收紧。
            var peer: String?
            if fromLAN {
                guard lanPolicy.allows(client.endpoint) else { return nil }
                peer = LANPeerPolicy.ipv4Text(of: client.endpoint) ?? Self.hostText(client.endpoint)
            }
            let id = UUID()
            let backend = NWConnection(
                host: NWEndpoint.Host(HelperConstants.loopbackAddress),
                port: nwPort,
                using: .tcp
            )
            var byteRecorder: (@Sendable (String, Int, Bool) -> Void)?
            if peer != nil {
                byteRecorder = { [weak self] address, count, isUpload in
                    self?.recordBytes(address: address, count: count, isUpload: isUpload)
                }
            }
            let closeHandler: @Sendable (UUID, String?) -> Void = { [weak self] id, address in
                guard let self else { return }
                self.lock.withLock {
                    self.pairs[id] = nil
                    if let address, var entry = self.lanStats[address] {
                        entry.activeConnections = max(entry.activeConnections - 1, 0)
                        self.lanStats[address] = entry
                    }
                }
            }
            let pair = RelayPair(
                id: id,
                client: client,
                backend: backend,
                queue: queue,
                peer: peer,
                onBytes: byteRecorder,
                onClose: closeHandler
            )
            if let peer { openClient(peer) }
            pairs[id] = pair
            return pair
        }
        guard let pair else {
            client.cancel()
            return
        }
        pair.start()
    }

    /// 调用方已持锁。
    private func openClient(_ address: String) {
        let now = Date()
        if var existing = lanStats[address] {
            existing.activeConnections += 1
            existing.lastActiveAt = now
            lanStats[address] = existing
        } else {
            if lanStats.count >= Self.maxTrackedClients,
               let oldest = lanStats.filter({ $0.value.activeConnections == 0 })
                   .min(by: { $0.value.lastActiveAt < $1.value.lastActiveAt })?.key {
                lanStats[oldest] = nil
            }
            lanStats[address] = MutableClientStats(
                activeConnections: 1,
                firstSeenAt: now,
                lastActiveAt: now
            )
        }
    }

    private func recordBytes(address: String, count: Int, isUpload: Bool) {
        lock.withLock {
            guard var entry = lanStats[address] else { return }
            if isUpload { entry.upload += Int64(count) } else { entry.download += Int64(count) }
            entry.lastActiveAt = Date()
            lanStats[address] = entry
        }
    }

    static func hostText(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        return "\(host)"
    }
}

extension LocalTCPRelay {
    /// 来源是不是私网/回环。判据按 RFC 1918、RFC 4193 与链路本地地址，
    /// 与「内网」这个直觉一致；公网来源一律拒绝。
    static func isPrivatePeer(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            let bytes = address.rawValue.map { $0 }
            guard bytes.count == 4 else { return false }
            if bytes[0] == 127 { return true }                                  // 回环
            if bytes[0] == 10 { return true }                                   // 10/8
            if bytes[0] == 172, (16...31).contains(bytes[1]) { return true }     // 172.16/12
            if bytes[0] == 192, bytes[1] == 168 { return true }                  // 192.168/16
            if bytes[0] == 169, bytes[1] == 254 { return true }                  // 链路本地
            return false
        case let .ipv6(address):
            if address.isLoopback || address.isLinkLocal { return true }
            let bytes = address.rawValue.map { $0 }
            guard let first = bytes.first else { return false }
            // fc00::/7 唯一本地地址。IPv4 映射地址（::ffff:a.b.c.d）按其 IPv4 部分判定。
            if first & 0xFE == 0xFC { return true }
            if bytes.count == 16, bytes.prefix(10).allSatisfy({ $0 == 0 }),
               bytes[10] == 0xFF, bytes[11] == 0xFF {
                let v4 = Array(bytes[12...])
                if v4[0] == 127 || v4[0] == 10 { return true }
                if v4[0] == 172, (16...31).contains(v4[1]) { return true }
                if v4[0] == 192, v4[1] == 168 { return true }
                if v4[0] == 169, v4[1] == 254 { return true }
            }
            return false
        default:
            return false
        }
    }
}

private final class StartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?

    init(continuation: CheckedContinuation<UInt16, Error>) {
        self.continuation = continuation
    }

    func succeed(_ port: UInt16) {
        lock.withLock {
            continuation?.resume(returning: port)
            continuation = nil
        }
    }

    func fail(_ error: Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

private final class RelayPair: @unchecked Sendable {
    private let id: UUID
    private let client: NWConnection
    private let backend: NWConnection
    private let queue: DispatchQueue
    /// 局域网客户端的地址。本机来的连接为 nil，不计量——那是系统代理自己的流量，
    /// 记进「局域网客户端」只会把用户看糊涂。
    let peer: String?
    private let onBytes: (@Sendable (String, Int, Bool) -> Void)?
    private let onClose: @Sendable (UUID, String?) -> Void
    private let lock = NSLock()
    private var closed = false
    private var completedDirections = 0

    var isFromLAN: Bool { peer != nil }

    init(
        id: UUID,
        client: NWConnection,
        backend: NWConnection,
        queue: DispatchQueue,
        peer: String? = nil,
        onBytes: (@Sendable (String, Int, Bool) -> Void)? = nil,
        onClose: @escaping @Sendable (UUID, String?) -> Void
    ) {
        self.id = id
        self.client = client
        self.backend = backend
        self.queue = queue
        self.peer = peer
        self.onBytes = onBytes
        self.onClose = onClose
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        backend.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        client.start(queue: queue)
        backend.start(queue: queue)
        pump(from: client, to: backend)
        pump(from: backend, to: client)
    }

    func cancel() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        client.cancel()
        backend.cancel()
        onClose(id, peer)
    }

    private func handle(_ state: NWConnection.State) {
        if case .failed = state { cancel() }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        // 方向由源端决定：客户端读到的是"客户端上传"，后端读到的是"下载给客户端"。
        let isUpload = source === client
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            if error != nil {
                self.cancel()
                return
            }

            if let data, !data.isEmpty {
                if let peer = self.peer, let onBytes = self.onBytes {
                    onBytes(peer, data.count, isUpload)
                }
                destination.send(
                    content: data,
                    contentContext: .defaultStream,
                    isComplete: complete,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil {
                            self.cancel()
                        } else if complete {
                            self.finishDirection()
                        } else {
                            self.pump(from: source, to: destination)
                        }
                    }
                )
            } else if complete {
                destination.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.cancel() } else { self.finishDirection() }
                    }
                )
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func finishDirection() {
        let finished = lock.withLock {
            guard !closed else { return false }
            completedDirections += 1
            return completedDirections == 2
        }
        if finished { cancel() }
    }
}
