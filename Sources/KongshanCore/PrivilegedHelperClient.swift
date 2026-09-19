import Darwin
import Foundation
import HelperProtocol

/// 与特权助手通信失败。
public enum PrivilegedHelperClientError: Error, Equatable, LocalizedError {
    case socketConnectFailed(String)
    case helperNotReachable
    case sendFailed(String)
    case receiveFailed
    case helperRejected(String)
    case noKernelPID
    case pipeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .socketConnectFailed(message): "无法连接特权助手：\(message)"
        case .helperNotReachable: "特权助手未安装或未运行"
        case let .sendFailed(message): "发送给助手失败：\(message)"
        case .receiveFailed: "未收到助手响应"
        case let .helperRejected(message): "助手拒绝：\(message)"
        case .noKernelPID: "助手未返回内核 PID"
        case let .pipeFailed(message): "无法传递 TUN 配置：\(message)"
        }
    }
}

/// 与特权助手通信的客户端。符合 `PrivilegedLaunching`，可替换 `PrivilegedLauncher`。
///
/// 助手可达时 TUN 启停零弹窗；不可达时 AppState 回退 `PrivilegedLauncher`（osascript）。
/// 配置经 `pipe()` 只读 FD + `sendmsg`/`SCM_RIGHTS` 传给 helper（§1.3 不落盘）。
public actor PrivilegedHelperClient: PrivilegedLaunching {
    private let socketPath: String
    private let binaryURL: URL
    private let now: @Sendable () -> Date
    /// socket 读写超时。helper 正常响应在毫秒级，超时即视作卡死/异常。
    private let ioTimeout: TimeInterval

    public init(
        binaryURL: URL,
        socketPath: String = HelperConstants.socketPath,
        now: @escaping @Sendable () -> Date = Date.init,
        ioTimeout: TimeInterval = 5
    ) {
        self.binaryURL = binaryURL.standardizedFileURL.resolvingSymlinksInPath()
        self.socketPath = socketPath
        self.now = now
        self.ioTimeout = ioTimeout
    }

    /// 发 status 请求。不可达或无响应返回 nil。
    public func status() -> HelperResponse? {
        guard let fd = connectSocket() else { return nil }
        defer { close(fd) }
        do {
            try sendFrame(HelperRequest.status, configFD: nil, on: fd)
        } catch {
            return nil
        }
        return receiveFrame(on: fd)
    }

    // MARK: - PrivilegedLaunching

    public func start(config: Data) async throws -> PrivilegedProcessRecord {
        guard let fd = connectSocket() else { throw PrivilegedHelperClientError.helperNotReachable }
        defer { close(fd) }

        // §1.3 配置经 pipe 只读 FD 传：读端经 SCM_RIGHTS 传给 helper，sing-box 从 stdin 读。
        // 修复 B（死锁）：先把读端交给 helper（sendmsg 复制 FD 进 socket），helper spawn sing-box
        // 开始读 stdin 后，再后台并发写配置。若先 writeAll 再 sendFrame，配置 > pipe 缓冲(~64KB)
        // 会因无人读而阻塞 → 死锁。真实机场配置常达数百 KB。
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            throw PrivilegedHelperClientError.pipeFailed(String(cString: strerror(errno)))
        }
        let readEnd = pipeFDs[0]
        let writeEnd = pipeFDs[1]

        // 1) 先把读端经 sendmsg 交给 helper。
        // 修复 N2：sendFrame 抛错时 pipe 两端都没人关（App 进程内泄漏，非提权）。
        // do/catch 在抛错路径补关两端，再 rethrow。成功后 readEnd 显式关（helper 已拿副本），
        // writeEnd 交给后台线程写完再关。
        do {
            try sendFrame(HelperRequest.startTun, configFD: readEnd, on: fd)
        } catch {
            close(readEnd)
            close(writeEnd)
            throw error
        }
        // helper 已通过 SCM_RIGHTS 拿到读端副本，App 关掉自己持有的读端。
        close(readEnd)

        // 2) 后台线程并发写配置到 writeEnd，sing-box 边读边排空 pipe。
        //    helper 若拒绝且关掉读端，写端会得 EPIPE/SIGPIPE——后台线程容错退出，不卡死。
        //    actor 上下文不能阻塞等它；helper 的响应是这次启动的权威结果。
        let configCopy = config
        Thread.detachNewThread {
            // SIGPIPE 默认会终止进程，写端收到时需忽略（write 返回 -1/EPIPE）。
            signal(SIGPIPE, SIG_IGN)
            try? self.writeAllSync(configCopy, to: writeEnd)
            close(writeEnd)
        }

        // 3) 等 helper 响应（helper spawn 后即回，不依赖 sing-box 读完配置）。
        guard let response = receiveFrame(on: fd) else {
            throw PrivilegedHelperClientError.receiveFailed
        }
        guard response.ok else {
            throw PrivilegedHelperClientError.helperRejected(response.message)
        }
        guard let pid = response.kernelPID else {
            throw PrivilegedHelperClientError.noKernelPID
        }
        // binaryPath 仅用于 AppState 的进程监控/记录对齐；helper 模式下 App 不做 processMatches 校验
        //（helper 已用 proc_pidpath 验证）。填内置 sing-box 路径保持记录结构一致。
        return PrivilegedProcessRecord(pid: pid, binaryPath: binaryURL.path, launchedAt: now())
    }

    /// 同步写全部数据到 FD（后台线程用）。EPIPE 容错转 pipeFailed。
    private nonisolated func writeAllSync(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset < ptr.count {
                let n = Darwin.write(fd, base.advanced(by: offset), ptr.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    // EPIPE：helper 关了读端（拒绝/异常），后台写直接退出，不视为致命错。
                    if errno == EPIPE { return }
                    throw PrivilegedHelperClientError.pipeFailed(String(cString: strerror(errno)))
                }
                offset += n
            }
        }
    }

    public func stop() async throws {
        guard let fd = connectSocket() else { throw PrivilegedHelperClientError.helperNotReachable }
        defer { close(fd) }
        try sendFrame(HelperRequest.stopTun, configFD: nil, on: fd)
        guard let response = receiveFrame(on: fd) else {
            throw PrivilegedHelperClientError.receiveFailed
        }
        guard response.ok else {
            throw PrivilegedHelperClientError.helperRejected(response.message)
        }
    }

    public func recoverIfNeeded() async throws {
        // 助手模式下，helper 内部 30s 自愈定时器负责清理残留内核（clientPID 不在则停）。
        // App 端兜底：若 status 显示内核仍在跑（上次崩溃后 helper 还没自愈），主动发 stopTun 清理，
        // 让 App 以干净状态重启。与 PrivilegedLauncher.recoverIfNeeded 语义对齐。
        guard let response = status() else { return }
        if response.ok, response.kernelPID != nil {
            try await stop()
        }
    }

    // MARK: - 内部：socket / 帧收发

    /// 建立到 helper socket 的连接。Unix domain socket 本地 connect：
    /// helper 未跑/未装时立即返回 ENOENT/ECONNREFUSED；helper 在跑时本地 ms 级成功。
    /// 设置 SO_RCVTIMEO/SO_SNDTIMEO 防止 helper 卡死时 App 挂死。
    private nonisolated func connectSocket() -> Int32? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var tv = timeval(tv_sec: Int(ioTimeout), tv_usec: Int32((ioTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000))
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(socketPath.utf8)
            // sun_path 末尾已有 0 填充（C 数组零初始化），只拷贝路径字节。
            buf.copyBytes(from: bytes)
        }
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private nonisolated func sendFrame(_ request: HelperRequest, configFD: Int32?, on fd: Int32) throws {
        let frame = try HelperFraming.encode(request)
        do {
            try HelperWire.send(frame: frame, fd: configFD, on: fd)
        } catch {
            throw PrivilegedHelperClientError.sendFailed(error.localizedDescription)
        }
    }

    private nonisolated func receiveFrame(on fd: Int32) -> HelperResponse? {
        let (body, extraFD) = HelperWire.receive(on: fd)
        // helper 不该回传 fd；真回了就关掉，别泄漏。
        if let extraFD { close(extraFD) }
        guard let body else { return nil }
        return try? HelperFraming.decode(HelperResponse.self, from: body)
    }

    private nonisolated func readFully(_ fd: Int32, _ ptr: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var offset = 0
        while offset < count {
            let n = read(fd, ptr.advanced(by: offset), count - offset)
            if n == 0 { return offset }       // EOF
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            offset += n
        }
        return offset
    }
}
