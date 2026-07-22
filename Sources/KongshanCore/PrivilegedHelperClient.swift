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

    /// socket 文件存在且可连。nonisolated 让调用方无需 await 即可判定是否回退兜底。
    public nonisolated func isReachable() -> Bool {
        connectSocket() != nil
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

        // §1.3 配置经 pipe 只读 FD 传：写端喂完 config 后关闭，读端经 SCM_RIGHTS 传给 helper。
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            throw PrivilegedHelperClientError.pipeFailed(String(cString: strerror(errno)))
        }
        let readEnd = pipeFDs[0]
        let writeEnd = pipeFDs[1]
        try writeAll(config, to: writeEnd)
        close(writeEnd)

        try sendFrame(HelperRequest.startTun, configFD: readEnd, on: fd)
        // helper 已通过 SCM_RIGHTS 拿到读端副本，App 关掉自己持有的读端。
        close(readEnd)

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
        if let configFD {
            try frame.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                try sendmsgWithFD(fd, body: base, length: ptr.count, fdToSend: configFD)
            }
        } else {
            try frame.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
                guard let base = ptr.baseAddress else { return }
                try sendAll(fd, body: base, count: ptr.count)
            }
        }
    }

    /// sendmsg 同时传 SCM_RIGHTS FD（§1.3）。CMSG_FIRSTHDR/DATA 宏 Swift 不可用，手写。
    /// 单 FD 场景只需一个 cmsg，与 helper 端 recvBodyAndFD 对称。
    private nonisolated func sendmsgWithFD(_ fd: Int32, body: UnsafeRawPointer, length: Int, fdToSend: Int32) throws {
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: body), iov_len: length)
        // CMSG_SPACE(sizeof(Int32)) = __DARWIN_ALIGN32(sizeof(cmsghdr) + sizeof(Int32))。
        let cmsgSpace = (MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 3) & ~3
        let cmsgBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: cmsgSpace, alignment: MemoryLayout<Int>.alignment)
        defer { cmsgBuf.deallocate() }

        var msg = msghdr()
        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1
        msg.msg_control = cmsgBuf.baseAddress
        msg.msg_controllen = socklen_t(cmsgSpace)

        // 填 cmsg 头 + 数据。
        let cmsg = cmsgBuf.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type = SCM_RIGHTS
        cmsg.pointee.cmsg_len = socklen_t(cmsgSpace)
        // CMSG_DATA(cmsg) = (char*)cmsg + __DARWIN_ALIGN32(sizeof(cmsghdr))。
        let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
        var fdVal = fdToSend
        withUnsafePointer(to: &fdVal) { fdPtr in
            UnsafeMutableRawPointer(cmsg)
                .advanced(by: dataOffset)
                .assumingMemoryBound(to: Int32.self)
                .pointee = fdPtr.pointee
        }

        let n = sendmsg(fd, &msg, 0)
        guard n >= 0 else {
            throw PrivilegedHelperClientError.sendFailed(String(cString: strerror(errno)))
        }
    }

    private nonisolated func sendAll(_ fd: Int32, body: UnsafeRawPointer, count: Int) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, body.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw PrivilegedHelperClientError.sendFailed(String(cString: strerror(errno)))
            }
            offset += n
        }
    }

    private nonisolated func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var offset = 0
            while offset < ptr.count {
                let n = Darwin.write(fd, base.advanced(by: offset), ptr.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PrivilegedHelperClientError.pipeFailed(String(cString: strerror(errno)))
                }
                offset += n
            }
        }
    }

    private nonisolated func receiveFrame(on fd: Int32) -> HelperResponse? {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let readLen = lengthBytes.withUnsafeMutableBufferPointer { buf in
            readFully(fd, buf.baseAddress!, 4)
        }
        guard readLen == 4 else { return nil }
        let length = (Int(lengthBytes[0]) << 24) | (Int(lengthBytes[1]) << 16)
            | (Int(lengthBytes[2]) << 8) | Int(lengthBytes[3])
        guard length > 0, length <= HelperFraming.maxFrameBytes else { return nil }

        var body = Data(count: length)
        let received = body.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            readFully(fd, ptr.baseAddress!, length)
        }
        guard received == length else { return nil }
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
