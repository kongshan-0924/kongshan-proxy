import Darwin
import Foundation
import HelperProtocol
import Security

// kongshan 特权助手（以 root 由 launchd 运行）。职责单一：起/停内置 sing-box TUN 内核。
//
// ⚠️ 安全关键组件。设计与威胁模型见 docs/design/tun-passwordless-helper.md。
// 铁律（任务书 §1，违反即打回）：
//   §1.1 只 exec 内置 sing-box（路径由 helper 自身位置推导 + exec 前校验签名），参数固定 run，配置从 stdin。
//        HelperRequest 无任何路径/命令/参数字段。
//   §1.2 拒绝优先：对端身份校验未过一律拒（含 status）。
//   §1.3 配置不落盘、不进命令行/环境变量，只经 socket SCM_RIGHTS 传只读 FD → sing-box stdin。
//   §1.4 只杀自己起的、且命令行匹配内置 sing-box 的 PID。不接受外部传入 PID。
//   §1.5 不在自动化里真安装 daemon（安装由用户在真机点一次授权）。
//   §1.6 不弱化 PrivilegedLauncher 兜底（未装助手时 TUN 仍走它）。

let helperVersion = "0.1.0"

/// 日志文件（root 拥有、0644，App 普通用户可读以查看 TUN 日志）。
/// 日志只含 sing-box 运行日志，不含凭据（secret 只在内存、config 经 stdin 不落盘）。
let logURL = URL(fileURLWithPath: HelperConstants.stateDirectory + "/sing-box-tun.log")
/// 日志体积上限。超限则启动时截断保留尾部，防无限增长。
let logByteLimit = 5 * 1024 * 1024

enum HelperError: Error, LocalizedError {
    case socketSetupFailed(String)
    case identityExtractFailed
    case singBoxNotFound
    case singBoxSignatureInvalid
    case logOpenFailed
    case spawnFailed(Int32)
    case invalidPID
    case processMismatch(Int32)

    var errorDescription: String? {
        switch self {
        case let .socketSetupFailed(message): "socket 建立失败：\(message)"
        case .identityExtractFailed: "无法提取对端身份"
        case .singBoxNotFound: "找不到内置 sing-box"
        case .singBoxSignatureInvalid: "内置 sing-box 签名校验失败"
        case .logOpenFailed: "无法打开日志文件"
        case let .spawnFailed(code): "启动 sing-box 失败：\(code)"
        case .invalidPID: "无效 PID"
        case let .processMismatch(pid): "进程身份校验失败（PID \(pid)）"
        }
    }
}

/// helper 共享状态。单线程串行处理连接 + 后台信号/自愈定时器访问，用锁保护。
/// @unchecked Sendable：所有可变字段经 lock 串行化访问。
final class HelperState: @unchecked Sendable {
    private let lock = NSLock()
    /// §1.4：helper 自己起的 sing-box PID。stopTun 只对这个 PID 发 SIGINT（且校验命令行）。
    private var kernelPID: Int32 = 0
    /// §2b.4 自愈：startTun 成功时记录的调用方 App PID。App 长期不在则自动停内核。
    private var clientPID: pid_t = 0
    private var shouldExit = false

    func setKernelPID(_ pid: Int32) { lock.lock(); kernelPID = pid; lock.unlock() }
    func kernelPIDValue() -> Int32 { lock.lock(); defer { lock.unlock() }; return kernelPID }
    func clearKernelPID() -> Int32 { lock.lock(); defer { lock.unlock() }; let old = kernelPID; kernelPID = 0; return old }

    func setClientPID(_ pid: pid_t) { lock.lock(); clientPID = pid; lock.unlock() }
    func clientPIDValue() -> pid_t { lock.lock(); defer { lock.unlock() }; return clientPID }

    func requestExit() { lock.lock(); shouldExit = true; lock.unlock() }
    func shouldExitValue() -> Bool { lock.lock(); defer { lock.unlock() }; return shouldExit }
}

let state = HelperState()

// MARK: - 对端身份校验（§5.1）

/// 从连接 FD 提取对端身份：audit_token → SecCode → 签名信息 + 可执行路径。
/// 提取失败返回 nil（调用方按拒绝处理）。
func extractClientIdentity(connfd: Int32) -> HelperClientIdentity? {
    // §5.1 取对端审计令牌。失败→拒绝（返回 nil）。
    var token = audit_token_t()
    var tokenLen = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(connfd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &tokenLen) == 0 else {
        return nil
    }
    let tokenData = withUnsafeBytes(of: token) { Data($0) }

    // 由审计令牌构造 SecCode。
    var code: SecCode?
    let attrs: [CFString: Any] = [kSecGuestAttributeAudit: tokenData]
    guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
          let code else {
        return nil
    }

    // §5.1 校验签名有效 + identifier == clientSigningIdentifier。
    // 用 requirement 一次性校验；失败则 signatureValid=false（纯函数据此拒绝）。
    var requirement: SecRequirement?
    let reqString = "identifier \"\(HelperConstants.clientSigningIdentifier)\""
    _ = SecRequirementCreateWithString(reqString as CFString, [], &requirement)
    let checkStatus = SecCodeCheckValidityWithErrors(code, [], requirement, nil)
    let signatureValid = (checkStatus == errSecSuccess)

    // 取签名信息：identifier + cdhash（kSecCodeInfoUnique）。
    // SecCodeCopySigningInformation 需要 SecStaticCode，先由 guest code 转换。
    var signingIdentifier: String?
    var cdHashHex: String?
    var staticCode: SecStaticCode?
    if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let info {
            let dict = info as! [String: Any]
            signingIdentifier = dict[kSecCodeInfoIdentifier as String] as? String
            if let cdhash = dict[kSecCodeInfoUnique as String] as? Data {
                cdHashHex = cdhash.map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    // §5.1 取对端可执行路径，须 == trust.clientExecutablePath。
    // SecCodeCopyPath 只接受 SecStaticCode；运行进程的 SecCode 用 proc_pidpath 取可执行路径更直接。
    var executablePath: String?
    let peerPIDValue = peerPID(connfd: connfd)
    if peerPIDValue > 0 {
        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLen = proc_pidpath(peerPIDValue, &pathBuf, UInt32(MAXPATHLEN))
        if pathLen > 0 {
            let nullIndex = pathBuf.firstIndex(of: 0) ?? pathBuf.count
            let pathString = String(decoding: pathBuf[0..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            executablePath = URL(fileURLWithPath: pathString).resolvingSymlinksInPath().path
        }
    }

    return HelperClientIdentity(
        signatureValid: signatureValid,
        signingIdentifier: signingIdentifier,
        executablePath: executablePath,
        cdHashHex: cdHashHex
    )
}

/// 取对端 PID（用于自愈检查）。失败返回 0。
func peerPID(connfd: Int32) -> pid_t {
    var pid = pid_t(0)
    var len = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(connfd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 else { return 0 }
    return pid
}

// MARK: - 内置 sing-box：路径推导 + 签名校验 + 起停（§1.1 / §1.4）

/// §1.1 内置 sing-box 路径：由 helper 自身可执行位置推导（同 .app 内 ../Resources/sing-box）。
/// helper 不接受外部传入的路径。
func singBoxURL() -> URL? {
    let helperPath = CommandLine.arguments.first ?? ""
    guard !helperPath.isEmpty else { return nil }
    let helperURL = URL(fileURLWithPath: helperPath).standardizedFileURL.resolvingSymlinksInPath()
    let resolved = helperURL
        .deletingLastPathComponent()
        .appendingPathComponent("../Resources/sing-box")
        .standardizedFileURL
        .resolvingSymlinksInPath()
    guard FileManager.default.isExecutableFile(atPath: resolved.path) else { return nil }
    return resolved
}

/// §1.1 exec 前校验内置 sing-box 签名有效（防被替换/篡改）。ad-hoc 签名也校验有效性。
func verifySingBoxSignature(at url: URL) throws {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
        throw HelperError.singBoxSignatureInvalid
    }
    // nil requirement：只校验签名本身有效（未被篡改），不附加 identifier/TeamID 约束。
    // sing-box 是本项目捆绑的，路径已由 helper 位置固定，无需再钉 identifier。
    guard SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
        throw HelperError.singBoxSignatureInvalid
    }
}

/// §2b.3 起内核：configFD 喂给 sing-box stdin，stdout/stderr 重定向到日志文件。
/// 返回 sing-box PID。helper 在 spawn 后关闭自己持有的 configFD/logFD（子进程经 dup2 持有副本）。
func startSingBox(at url: URL, configFD: Int32) throws -> Int32 {
    try verifySingBoxSignature(at: url)

    // 日志文件：O_CREAT|O_APPEND，0644 让 App 可读（日志不含凭据）。
    let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
    guard logFD >= 0 else { throw HelperError.logOpenFailed }

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // §1.3 configFD → sing-box stdin。配置不落盘、不进命令行/环境变量。
    posix_spawn_file_actions_adddup2(&actions, configFD, STDIN_FILENO)
    // 日志重定向。
    posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO)

    var attrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }

    // §1.1 参数固定 run（从 stdin 读配置，无 -c）。
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(url.path), strdup("run"), nil]
    defer { argv.forEach { free($0) } }
    let spawnResult = argv.withUnsafeBufferPointer { argvBuf in
        posix_spawn(&pid, url.path, &actions, &attrs, argvBuf.baseAddress, nil)
    }
    // helper 不再需要 configFD/logFD（子进程已有副本）。
    close(configFD)
    close(logFD)

    guard spawnResult == 0, pid > 0 else { throw HelperError.spawnFailed(spawnResult) }
    return pid
}

/// §1.4 停内核：只对 helper 自己起的 PID 发 SIGINT，且先验证其命令行确为内置 sing-box。
func stopSingBox(pid: Int32, expectedURL: URL) throws {
    guard pid > 1 else { throw HelperError.invalidPID }
    // §1.4 验证进程的可执行路径 == 内置 sing-box 路径，绝不按外部 PID 盲杀。
    let expected = expectedURL.resolvingSymlinksInPath().path
    var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let len = proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
    guard len > 0 else { throw HelperError.processMismatch(pid) }
    let nullIndex = pathBuf.firstIndex(of: 0) ?? pathBuf.count
    let actualPath = String(decoding: pathBuf[0..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let actual = URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().path
    guard actual == expected else { throw HelperError.processMismatch(pid) }
    // SIGINT 让 sing-box 优雅退出（释放 utun/路由），与现有兜底行为一致。
    kill(pid, SIGINT)
}

// MARK: - 连接处理（收请求帧 + SCM_RIGHTS FD + 决策 + 执行）

/// 读 n 字节（循环至 n 或 EOF/错误）。
func readFully(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
    var offset = 0
    while offset < count {
        let n = read(fd, buffer.advanced(by: offset), count - offset)
        if n == 0 { return offset }       // EOF
        if n < 0 {
            if errno == EINTR { continue }
            return -1
        }
        offset += n
    }
    return offset
}

/// recvmsg 收 body 同时取 SCM_RIGHTS 里的只读 FD（§1.3）。无 FD 时 receivedFD 保持 -1。
/// 注意：CMSG_FIRSTHDR / CMSG_DATA / CMSG_NXTHDR 是 C 宏，Swift 不可用，这里手写对等逻辑。
/// 单 FD 场景只需首个 cmsg，不做 NXTHDR 遍历。
func recvBodyAndFD(_ fd: Int32, body: UnsafeMutableRawPointer, length: Int) -> (received: Int, configFD: Int32) {
    var configFD: Int32 = -1
    var iov = iovec(iov_base: body, iov_len: length)
    // CMSG_SPACE(sizeof(Int32)) = __DARWIN_ALIGN32(sizeof(cmsghdr) + 4)。手算对齐到 4 字节。
    let cmsgSpace = (MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 3) & ~3
    let cmsgBuf = UnsafeMutableRawBufferPointer.allocate(byteCount: cmsgSpace, alignment: MemoryLayout<Int>.alignment)
    defer { cmsgBuf.deallocate() }

    var msg = msghdr()
    msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
    msg.msg_iovlen = 1
    msg.msg_control = cmsgBuf.baseAddress
    msg.msg_controllen = socklen_t(cmsgSpace)

    let n = recvmsg(fd, &msg, 0)
    guard n >= 0 else { return (-1, -1) }

    // CMSG_FIRSTHDR：msg_controllen >= sizeof(cmsghdr) 时返回 msg_control 作为 cmsghdr 指针。
    guard msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size),
          let control = msg.msg_control else { return (Int(n), -1) }
    let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
    if cmsg.pointee.cmsg_level == SOL_SOCKET && cmsg.pointee.cmsg_type == SCM_RIGHTS {
        // CMSG_DATA(cmsg) = (char*)cmsg + __DARWIN_ALIGN32(sizeof(cmsghdr))。
        let dataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3
        let dataPtr = UnsafeMutableRawPointer(cmsg).advanced(by: dataOffset)
        configFD = dataPtr.assumingMemoryBound(to: Int32.self).pointee
    }
    return (Int(n), configFD)
}

/// 收一帧请求（4 字节大端长度 + JSON body），并尝试取 SCM_RIGHTS FD。
func recvRequest(connfd: Int32) -> (request: HelperRequest?, configFD: Int32?) {
    var lengthBytes = [UInt8](repeating: 0, count: 4)
    let readLen = lengthBytes.withUnsafeMutableBufferPointer { buf in
        readFully(connfd, buf.baseAddress!, 4)
    }
    guard readLen == 4 else { return (nil, nil) }
    let length = (Int(lengthBytes[0]) << 24) | (Int(lengthBytes[1]) << 16)
        | (Int(lengthBytes[2]) << 8) | Int(lengthBytes[3])
    guard length > 0, length <= HelperFraming.maxFrameBytes else { return (nil, nil) }

    var body = Data(count: length)
    let (received, fd): (Int, Int32) = body.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) -> (Int, Int32) in
        guard let base = ptr.baseAddress else { return (-1, -1) }
        return recvBodyAndFD(connfd, body: base, length: length)
    }
    guard received == length else { return (nil, nil) }

    let request = try? HelperFraming.decode(HelperRequest.self, from: body)
    let configFD: Int32? = fd >= 0 ? fd : nil
    return (request, configFD)
}

/// 发一帧响应。
func sendResponse(_ response: HelperResponse, connfd: Int32) {
    guard let frame = try? HelperFraming.encode(response) else { return }
    _ = frame.withUnsafeBytes { ptr in
        write(connfd, ptr.baseAddress, ptr.count)
    }
}

/// 处理一个连接：鉴权 → 收请求 → 决策 → 执行 → 回响应 → 关连接。
func handleConnection(connfd: Int32, singBox: URL) {
    defer { close(connfd) }

    // §5.1 对端身份校验。失败→拒绝（直接断连，不处理任何请求）。
    let trust: HelperTrustConfig
    guard let loadedTrust = HelperSecurity.loadTrustConfig() else {
        return  // trust.json 缺失/损坏 → 一律拒绝，静默断连。
    }
    trust = loadedTrust

    guard let identity = extractClientIdentity(connfd: connfd),
          HelperTrustEvaluation.isTrusted(identity: identity, trust: trust) else {
        return  // §1.2 未鉴权 → 拒绝。
    }

    let (request, configFD) = recvRequest(connfd: connfd)
    guard let request else { return }  // 解析失败 → 断连。

    let kernelRunning = state.kernelPIDValue() > 0
    let decision = HelperDecision.decide(
        request: request,
        isTrusted: true,
        hasConfigFD: configFD != nil,
        kernelRunning: kernelRunning
    )

    switch decision {
    case .replyStatus:
        // status 回 helper 版本 + 内核是否在跑（不泄露敏感信息）。
        sendResponse(HelperResponse(
            ok: true,
            message: kernelRunning ? "running" : "idle",
            kernelPID: kernelRunning ? state.kernelPIDValue() : nil,
            helperVersion: helperVersion
        ), connfd: connfd)

    case .startKernel:
        guard let fd = configFD else {
            sendResponse(HelperResponse(ok: false, message: "missing config fd"), connfd: connfd)
            return
        }
        do {
            let pid = try startSingBox(at: singBox, configFD: fd)
            state.setKernelPID(pid)
            // §2b.4 记录调用方 PID，供自愈检查。
            state.setClientPID(peerPID(connfd: connfd))
            sendResponse(HelperResponse(ok: true, message: "started", kernelPID: pid, helperVersion: helperVersion), connfd: connfd)
        } catch {
            sendResponse(HelperResponse(ok: false, message: error.localizedDescription, helperVersion: helperVersion), connfd: connfd)
        }

    case .stopKernel:
        // §1.4 只停自己起的那个 PID。
        let pid = state.clearKernelPID()
        do {
            try stopSingBox(pid: pid, expectedURL: singBox)
            sendResponse(HelperResponse(ok: true, message: "stopped", helperVersion: helperVersion), connfd: connfd)
        } catch {
            // 停失败：把 PID 记回（可能仍活着），如实回报。
            state.setKernelPID(pid)
            sendResponse(HelperResponse(ok: false, message: error.localizedDescription, helperVersion: helperVersion), connfd: connfd)
        }

    case let .reject(message):
        sendResponse(HelperResponse(ok: false, message: message, helperVersion: helperVersion), connfd: connfd)
    }
}

// MARK: - 生命周期 / 自愈（§2b.4）

/// §2b.4 自愈：调用方 App 长期不在 → 自动停内核，避免残留 root 内核接管网络。
func checkClientLiveness(singBox: URL) {
    let kernelPID = state.kernelPIDValue()
    guard kernelPID > 0 else { return }
    let clientPID = state.clientPIDValue()
    guard clientPID > 0 else { return }
    // kill(pid, 0) 只检查进程存在（不发信号）。
    if kill(clientPID, 0) != 0 {
        // App 不在了，停自己起的内核。
        let pid = state.clearKernelPID()
        try? stopSingBox(pid: pid, expectedURL: singBox)
    }
}

/// 启动前若日志超限，截断保留尾部，防无限增长。
func rotateLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
          let size = attrs[.size] as? NSNumber, size.intValue > logByteLimit else { return }
    guard let data = try? Data(contentsOf: logURL) else { return }
    let tail = data.suffix(logByteLimit / 5)  // 保留约 1MB 尾部
    try? tail.write(to: logURL, options: .atomic)
    try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: logURL.path)
}

// MARK: - socket 服务（§2b.1）

/// §2b.1 建立 Unix domain socket：stateDirectory(root 0700) → unlink 旧 socket → bind → chmod 0600 → listen。
func setupSocket() -> Int32 {
    // stateDirectory：root 拥有、0700。
    _ = mkdir(HelperConstants.stateDirectory, mode_t(0o700))
    chmod(HelperConstants.stateDirectory, mode_t(0o700))

    // 清掉可能残留的旧 socket 文件。
    unlink(HelperConstants.socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = HelperConstants.socketPath
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        let pathBytes = Array(path.utf8)
        // sun_path 末尾已有 0 填充，这里只拷贝路径字节（不带结尾 0，C 数组零初始化）。
        buf.copyBytes(from: pathBytes)
    }
    let bindResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else { close(fd); return -1 }

    // §5.5 socket 0600（仅 root 可读写）。权限是次要防线，§5.1 校验才是主防线。
    chmod(HelperConstants.socketPath, mode_t(0o600))
    guard listen(fd, 5) == 0 else { close(fd); return -1 }
    return fd
}

/// 优雅退出：停内核（若在跑）、关 socket、unlink socket 文件。
func shutdownHelper(listenFD: Int32, singBox: URL) {
    let pid = state.clearKernelPID()
    if pid > 0 {
        try? stopSingBox(pid: pid, expectedURL: singBox)
    }
    shutdown(listenFD, Int32(SHUT_RDWR))
    close(listenFD)
    unlink(HelperConstants.socketPath)
}

// MARK: - 入口

// 信任配置加载（沿用骨架实现：读 trust.json，缺失/损坏返回 nil → 一律拒绝）。
enum HelperSecurity {
    static func loadTrustConfig() -> HelperTrustConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: HelperConstants.trustConfigPath)) else {
            return nil
        }
        return try? JSONDecoder().decode(HelperTrustConfig.self, from: data)
    }
}

guard let singBox = singBoxURL() else {
    FileHandle.standardError.write(Data("kongshan-helper: 找不到内置 sing-box，退出。\n".utf8))
    exit(EXIT_FAILURE)
}

rotateLogIfNeeded()

let listenFD = setupSocket()
guard listenFD >= 0 else {
    FileHandle.standardError.write(Data("kongshan-helper: socket 建立失败，退出。\n".utf8))
    exit(EXIT_FAILURE)
}

// §2b.1 信号优雅退出：SIGTERM/SIGINT → 设退出标志 + shutdown listenFD 让 poll 返回。
// 用 dispatch source 接管信号（先 SIG_IGN 让 dispatch 拦截）。
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let signalQueue = DispatchQueue(label: "kongshan.helper.signal")
for sig in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: signalQueue)
    source.setEventHandler {
        state.requestExit()
        shutdown(listenFD, Int32(SHUT_RDWR))
    }
    source.resume()
}

// §2b.4 自愈定时器：每 30s 检查调用方 App 是否还在，不在则停内核。
let livenessTimer = DispatchSource.makeTimerSource(queue: signalQueue)
livenessTimer.schedule(deadline: .now() + 30, repeating: 30)
livenessTimer.setEventHandler { [singBox] in
    checkClientLiveness(singBox: singBox)
}
livenessTimer.resume()

FileHandle.standardError.write(Data("kongshan-helper \(helperVersion): 监听 \(HelperConstants.socketPath)\n".utf8))

// §2b.1 accept 循环（单线程串行处理，够用）。用 poll 带 1s 超时周期检查 shouldExit。
while !state.shouldExitValue() {
    var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
    let n = poll(&pfd, 1, 1000)
    if n > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        let connfd = accept(listenFD, nil, nil)
        if connfd >= 0 {
            handleConnection(connfd: connfd, singBox: singBox)
        }
    } else if n < 0 && errno != EINTR {
        break
    }
}

shutdownHelper(listenFD: listenFD, singBox: singBox)
FileHandle.standardError.write(Data("kongshan-helper: 已退出。\n".utf8))
exit(EXIT_SUCCESS)
