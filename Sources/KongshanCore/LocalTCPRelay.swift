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
    func stop()
}

/// App 持有的稳定 loopback TCP 入口。它只转发原始字节，不解析 HTTP CONNECT 或 SOCKS。
/// 系统代理始终指向这里；sing-box 的 mixed inbound 则使用每代独立的内部端口。
public final class LocalTCPRelay: LocalTCPRelaying, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kaysen.kongshan.local-tcp-relay")
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var targetPort: UInt16?
    private var pairs: [UUID: RelayPair] = [:]

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
                self?.accept(connection)
            }
            candidate.start(queue: queue)
        }
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
        let snapshot: (NWListener?, [RelayPair]) = lock.withLock {
            let result = (listener, Array(pairs.values))
            listener = nil
            boundPort = nil
            targetPort = nil
            pairs.removeAll(keepingCapacity: false)
            return result
        }
        snapshot.0?.cancel()
        snapshot.1.forEach { $0.cancel() }
    }

    private func accept(_ client: NWConnection) {
        let pair: RelayPair? = lock.withLock {
            guard let targetPort,
                  let nwPort = NWEndpoint.Port(rawValue: targetPort) else { return nil }
            let id = UUID()
            let backend = NWConnection(
                host: NWEndpoint.Host(HelperConstants.loopbackAddress),
                port: nwPort,
                using: .tcp
            )
            let pair = RelayPair(id: id, client: client, backend: backend, queue: queue) { [weak self] id in
                self?.lock.withLock { self?.pairs[id] = nil }
            }
            pairs[id] = pair
            return pair
        }
        guard let pair else {
            client.cancel()
            return
        }
        pair.start()
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
    private let onClose: @Sendable (UUID) -> Void
    private let lock = NSLock()
    private var closed = false
    private var completedDirections = 0

    init(
        id: UUID,
        client: NWConnection,
        backend: NWConnection,
        queue: DispatchQueue,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.id = id
        self.client = client
        self.backend = backend
        self.queue = queue
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
        onClose(id)
    }

    private func handle(_ state: NWConnection.State) {
        if case .failed = state { cancel() }
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.lock.withLock({ self.closed }) else { return }
            if error != nil {
                self.cancel()
                return
            }

            if let data, !data.isEmpty {
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
