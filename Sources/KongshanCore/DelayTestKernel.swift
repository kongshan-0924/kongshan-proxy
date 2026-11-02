import Darwin
import Foundation

/// URL 测速（真实延迟）：让内核经节点请求测试地址，测到的是「新开一条代理连接到拿到响应」的耗时。
public protocol URLDelayTesting: Sendable {
    /// 准备好能测这批节点的内核。节点、解析器、物理网卡都没变时直接复用。
    func prepare(nodes: [ProxyNode], resolver: String) async throws
    func delay(of node: ProxyNode, testURL: URL, timeoutMilliseconds: Int) async -> DelayResult
    /// 一轮测完：空闲一阵再停，连着测不必反复起停。
    func finishSoon() async
    func shutdown() async
}

/// 测速专用的独立内核：用户态 sing-box，只装节点出站与 Clash API（见 `ConfigGenerator.delayTestConfig`）。
///
/// 旧做法借主内核测：没开接管时要先把主内核拉起来（整套配置、规则集、忙碌态，界面跟着锁住），
/// 开着接管时几十条测速连接又和正常上网挤在同一个内核里。独立出来后两边互不影响：
/// 开没开代理 / TUN 都能测，测速也不打扰正在用的连接。
public actor DelayTestKernel: URLDelayTesting {
    public static let idleLifetime: Duration = .seconds(60)

    private let binaryURL: URL
    /// 记下测速内核的 PID：App 崩溃时子进程不会跟着退，下次启动按它清掉。
    private let pidFileURL: URL
    private var process: SingBoxProcess?
    private var client: ClashAPIClient?
    private var preparedKey: Data?
    private var idleStop: Task<Void, Never>?
    /// 准备排队执行：批量测速进行中又点了单个节点测速时，两次准备在 actor 里交错会把刚起好的内核重起一遍。
    private var preparing: Task<Void, Error>?
    private let output = OutputTail()

    public init(binaryURL: URL, pidFileURL: URL) {
        self.binaryURL = binaryURL
        self.pidFileURL = pidFileURL
    }

    public func prepare(nodes: [ProxyNode], resolver: String) async throws {
        let previous = preparing
        let current = Task {
            _ = await previous?.result
            try await self.startIfNeeded(nodes: nodes, resolver: resolver)
        }
        preparing = current
        try await current.value
    }

    private func startIfNeeded(nodes: [ProxyNode], resolver: String) async throws {
        idleStop?.cancel()
        idleStop = nil
        let interface = PhysicalInterface.primary()?.name
        // 端口与 secret 每次随机，不能进比较键；其余（节点出站、解析器、网卡）任一变了就重起。
        let key = try ConfigGenerator.delayTestConfig(
            nodes: nodes, resolver: resolver, interfaceName: interface, clashPort: 0, secret: ""
        )
        if let process, await process.isRunning, key == preparedKey, client != nil { return }

        await stopProcess()
        reapStaleKernel()
        let port = try RuntimeSecrets.availableHighPort()
        let secret = try RuntimeSecrets.secret()
        let config = try ConfigGenerator.delayTestConfig(
            nodes: nodes, resolver: resolver, interfaceName: interface, clashPort: port, secret: secret
        )
        output.reset()
        let tail = output
        let process = SingBoxProcess(binaryURL: binaryURL, logHandler: { tail.append($0.text) })
        try await process.start(config: config)
        self.process = process
        if let pid = await process.currentPID {
            try? Data(String(pid).utf8).write(to: pidFileURL, options: .atomic)
        }

        let client = ClashAPIClient(controller: URL(string: "http://127.0.0.1:\(port)")!, secret: secret)
        // 几百个出站的配置起来通常不到 1 秒；等控制接口能应答再交出去。
        for _ in 0..<50 {
            if (try? await client.version()) != nil {
                self.client = client
                preparedKey = key
                return
            }
            guard await process.isRunning else { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let detail = output.text
        await stopProcess()
        throw DelayTestKernelError.startFailed(detail)
    }

    public func delay(of node: ProxyNode, testURL: URL, timeoutMilliseconds: Int) async -> DelayResult {
        guard let client else { return .failure("测速内核没有启动") }
        // 不写成「超时」：那两个字在界面上专指 TCP 握手 3 秒没连上（`AppState.readableDelayFailure`）。
        let timedOut = "\(timeoutMilliseconds / 1_000) 秒内经节点没拿到测试地址的响应"
        do {
            return .success(try await client.delay(
                node: ConfigGenerator.outboundTag(for: node),
                testURL: testURL,
                timeoutMilliseconds: timeoutMilliseconds
            ))
        } catch ClashAPIError.httpStatus(504) {
            return .failure(timedOut)
        } catch ClashAPIError.httpStatus(503) {
            return .failure("经节点请求测试地址失败")
        } catch ClashAPIError.httpStatus(404) {
            return .failure("节点不在测速内核里（配置缺字段）")
        } catch let error as URLError where error.code == .timedOut {
            return .failure(timedOut)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    public func finishSoon() {
        idleStop?.cancel()
        idleStop = Task { [weak self] in
            try? await Task.sleep(for: Self.idleLifetime)
            guard !Task.isCancelled else { return }
            await self?.stopProcess()
        }
    }

    public func shutdown() async {
        idleStop?.cancel()
        idleStop = nil
        await stopProcess()
    }

    private func stopProcess() async {
        client = nil
        preparedKey = nil
        guard let process else { return }
        self.process = nil
        await process.stop()
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    /// 上次 App 崩溃留下的测速内核：PID 还活着、而且确实是同一个 sing-box 才杀，避免 PID 复用误伤。
    private func reapStaleKernel() {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return }
        try? FileManager.default.removeItem(at: pidFileURL)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0,
              String(cString: buffer) == binaryURL.resolvingSymlinksInPath().path else { return }
        kill(pid, SIGKILL)
    }

    /// 内核起不来时报给用户的最后几行输出。
    private final class OutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ chunk: String) {
            lock.withLock {
                lines.append(contentsOf: chunk.split(whereSeparator: \.isNewline).map(String.init))
                if lines.count > 5 { lines.removeFirst(lines.count - 5) }
            }
        }

        func reset() { lock.withLock { lines.removeAll() } }
        var text: String { lock.withLock { lines.joined(separator: "\n") } }
    }
}

public enum DelayTestKernelError: Error, LocalizedError {
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .startFailed(detail):
            detail.isEmpty ? "测速内核没能启动" : "测速内核没能启动：\(detail)"
        }
    }
}
