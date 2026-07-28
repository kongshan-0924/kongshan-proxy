import Darwin
import Foundation
import HelperProtocol
import Security

// kongshan 特权助手（以 root 由 launchd 运行）。职责单一：起/停内置 sing-box TUN 内核。
//
// ⚠️ 安全关键组件。设计与威胁模型见 docs/design/tun-passwordless-helper.md。
// 铁律（任务书 §1，违反即打回）：
//   §1.1 只 exec 内置 sing-box（路径从 trust.json 读，安装时钉死为 root-only 拷贝；exec 前校验签名 +
//        cdhash 钉死），参数固定 `run -c /dev/stdin`，配置从只读管道 fd 读。HelperRequest 无任何路径/命令/参数字段。
//   §1.2 拒绝优先：对端身份校验未过一律拒（含 status）。
//   §1.3 配置不落盘、不进命令行/环境变量，只经 socket SCM_RIGHTS 传只读 FD → sing-box stdin（-c /dev/stdin）。
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
    // 修复 D2：别丢弃 SecRequirementCreateWithString 返回值——它失败时 requirement 为 nil，
    // SecCodeCheckValidityWithErrors(nil) 只验"签名有效"不验 identifier → 不安全（任意 identifier 都过）。
    // 失败按拒绝处理：reqCreated=false → signatureValid=false。
    var requirement: SecRequirement?
    let reqString = "identifier \"\(HelperConstants.clientSigningIdentifier)\""
    let reqCreated = (SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess)
    let checkStatus = SecCodeCheckValidityWithErrors(code, [], requirement, nil)
    let signatureValid = reqCreated && (checkStatus == errSecSuccess)

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
    // 修复 D2：路径从签名校验/签名信息用的同一 SecStaticCode 取（SecCodeCopyPath），
    // 别再 proc_pidpath(裸 LOCAL_PEERPID)——消除"socket → PID → path"的裸 PID 往返
    //（PID 与签名链路无关，且有竞态）。取不到 staticCode 或路径 → executablePath=nil
    // → 纯函数 isTrusted 因路径不匹配拒绝（拒绝优先）。
    var executablePath: String?
    if let staticCode {
        var pathURL: CFURL?
        if SecCodeCopyPath(staticCode, [], &pathURL) == errSecSuccess, let pathURL {
            executablePath = (pathURL as URL).resolvingSymlinksInPath().path
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

// MARK: - 内置 sing-box：路径 + 签名校验 + cdhash 钉死 + 起停（§1.1 / §1.4 / 修复 C）

/// 修复 C：sing-box 路径从 trust.json 读（安装时记录 bundle 内 sing-box 绝对路径），
/// 不再从 helper 自身位置相对推导。helper 被拷到 root-only 位置后，相对关系已变；
/// 且从 trust 读可让"bundle 内 sing-box 被换路径"也无济于事（路径仍是安装时记的）。
/// trust.json 缺 singBoxExecutablePath → nil → 启动失败（拒绝优先）。
func singBoxURL(from trust: HelperTrustConfig) -> URL? {
    guard let path = trust.singBoxExecutablePath, !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
    return url
}

/// §1.1 exec 前校验内置 sing-box：签名有效 + cdhash 钉死（修复 C）。
/// ad-hoc 签名零成本可伪造，光验"签名有效"挡不住替换；必须钉 cdhash。
/// 调用前的 trust 加载已要求 cdhash 完整；这里仍按纯函数结果拒绝不匹配。
func verifySingBoxSignature(at url: URL, pinnedCDHashHex: String?) throws {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
        throw HelperError.singBoxSignatureInvalid
    }
    // 签名本身有效（未被篡改）。
    guard SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
        throw HelperError.singBoxSignatureInvalid
    }
    // 修复 C：cdhash 钉死。取 kSecCodeInfoUnique 比对 trust.json 钉死值。
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let info else {
        // 取不到签名信息 → 若钉了 cdhash 则拒绝（拿不到就没法比），未钉则放行。
        if let pinned = pinnedCDHashHex, !pinned.isEmpty {
            throw HelperError.singBoxSignatureInvalid
        }
        return
    }
    let dict = info as! [String: Any]
    var actualCDHashHex: String?
    if let cdhash = dict[kSecCodeInfoUnique as String] as? Data {
        actualCDHashHex = cdhash.map { String(format: "%02x", $0) }.joined()
    }
    // 纯函数判定（便于单测）：未钉放行，钉了必须匹配。
    guard HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: actualCDHashHex, pinnedCDHashHex: pinnedCDHashHex) else {
        throw HelperError.singBoxSignatureInvalid
    }
}

/// §2b.3 起内核：configData 经新建只读 pipe FD 喂给 sing-box（`-c /dev/stdin`），
/// stdout/stderr 重定向到日志文件。返回 sing-box PID。
///
/// 纵深防御：调用方已用 `HelperConfigWhitelist.validate` 校验过 configData，
/// helper 不再把 App 传来的 FD 直喂 sing-box——先读入内存做 schema 白名单校验，
/// 通过后用本地新建 pipe 投递，杜绝 App 被攻破后塞武器化配置（如 clash_api 远控）。
///
/// 加固（BLOCKER②）：argv 必须带 `-c /dev/stdin`。stock sing-box 的 `run` 不带 -c 时只从 CWD
/// 找 config.json、完全无视 stdin（实测 1.13.14：`run` 报 open config.json，`run -c /dev/stdin`
/// 才读管道）。配置内容只存在于 helper 进程内存 + pipe，不落盘、不进 argv/环境变量（§1.3 保持）。
/// spawn 后短暂确认子进程未立即退出（配置错误会毫秒级 FATAL），否则会向 App 误报 started。
func startSingBox(at url: URL, configData: Data, pinnedCDHashHex: String?) throws -> Int32 {
    try verifySingBoxSignature(at: url, pinnedCDHashHex: pinnedCDHashHex)

    // 日志文件：O_CREAT|O_APPEND，0644 让 App 可读（日志不含凭据）。
    let logFD = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, mode_t(0o644))
    guard logFD >= 0 else { throw HelperError.logOpenFailed }
    defer { close(logFD) }

    // 新建 pipe：读端给 sing-box stdin，写端后台灌入已校验的 configData。
    var pipeFDs: [Int32] = [0, 0]
    guard pipe(&pipeFDs) == 0 else { throw HelperError.spawnFailed(errno) }
    let readEnd = pipeFDs[0]
    let writeEnd = pipeFDs[1]
    // **两端都必须置 FD_CLOEXEC**：`posix_spawn` 会把所有未标记 CLOEXEC 的 fd 原样继承给子进程。
    // 写端一旦被 sing-box 继承，它就自己握着自己 stdin 管道的写端——helper 这边写完关掉也
    // **永远等不到 EOF**，于是 sing-box 一直阻塞在读配置：进程活着、不监听任何端口、日志 0 字节，
    // App 侧表现为 "sing-box 控制接口未就绪：Could not connect to the server."。
    // 读端同理（真正给 stdin 的是 dup2 出来的副本，dup2 会清掉 CLOEXEC，不受影响）。
    _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

    var actions: posix_spawn_file_actions_t? = nil
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    // §1.3 readEnd → sing-box stdin（配合 `-c /dev/stdin` 读取）。
    posix_spawn_file_actions_adddup2(&actions, readEnd, STDIN_FILENO)
    // 日志重定向。
    posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO)
    posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO)

    var attrs: posix_spawnattr_t? = nil
    posix_spawnattr_init(&attrs)
    defer { posix_spawnattr_destroy(&attrs) }

    // §1.1 参数固定 `run -c /dev/stdin`。
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(url.path), strdup("run"), strdup("-c"), strdup("/dev/stdin"), nil
    ]
    defer { argv.forEach { free($0) } }
    let spawnResult = argv.withUnsafeBufferPointer { argvBuf in
        posix_spawn(&pid, url.path, &actions, &attrs, argvBuf.baseAddress, nil)
    }
    // spawn 后立即关读端（sing-box 经 dup2 持有副本，父进程关自己的不影响子进程）。
    close(readEnd)
    guard spawnResult == 0, pid > 0 else {
        close(writeEnd)
        throw HelperError.spawnFailed(spawnResult)
    }

    // 后台线程把已校验的 configData 灌进 writeEnd。sing-box 边读边排空 pipe。
    // 配置可达数百 KB，超 pipe 缓冲(~64KB)，必须并发写否则死锁。
    let configCopy = configData
    Thread.detachNewThread {
        signal(SIGPIPE, SIG_IGN)  // sing-box 早退关读端时写端收 EPIPE，别杀 helper
        _ = configCopy.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            var offset = 0
            while offset < ptr.count {
                let n = write(writeEnd, base.advanced(by: offset), ptr.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    break  // EPIPE 或其它，sing-box 已退/拒读，放弃
                }
                offset += n
            }
            return offset
        }
        close(writeEnd)
    }

    // 配置无效时 sing-box 毫秒级 FATAL 退出；短暂确认存活再回 started，否则误报成功。
    usleep(150_000)
    var wstatus: Int32 = 0
    if waitpid(pid, &wstatus, WNOHANG) == pid {
        throw HelperError.spawnFailed(-1)  // 子进程已退出（多半配置无效）→ 不误报 started
    }
    return pid
}

/// 取某 PID 的可执行路径（已解 symlink）。取不到返回 nil。
func executablePath(ofPID pid: Int32) -> String? {
    guard pid > 1 else { return nil }
    var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN)) > 0 else { return nil }
    let nullIndex = pathBuf.firstIndex(of: 0) ?? pathBuf.count
    let path = String(decoding: pathBuf[0..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// 扫现存进程，返回第一个可执行路径 == expected 的 PID。用于 helper 重启后认领残留内核
/// 与判断调用方 App 是否还在。expected 须是已解 symlink 的绝对路径。
func firstPID(withExecutablePath expected: String) -> Int32? {
    // ⚠️ proc_listallpids 的两个返回值都是**进程个数**，不是字节数（实测：返回 795 时
    // 缓冲区里正好 794 个非零 pid，与 ps 一致）。只有第二个入参是字节数，所以要乘 size。
    // 误当字节数去除以 4，会只扫到 1/4 的进程 —— 残留内核大概率漏掉，认领逻辑静默失效。
    let processCount = proc_listallpids(nil, 0)
    guard processCount > 0 else { return nil }
    var pids = [pid_t](repeating: 0, count: Int(processCount) + 64)  // 多留槽位应对扫描期间新起的进程
    let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard written > 0 else { return nil }
    for pid in pids.prefix(Int(written)) where pid > 1 {
        if executablePath(ofPID: pid) == expected { return pid }
    }
    return nil
}

/// 内核是否还活着。**必须先收尸**：sing-box 是 helper 的子进程，被信号杀死后会变成僵尸，
/// 此时 `kill(pid, 0)` 仍然返回 0——只看它会把"已经杀掉"误判成"还在跑"，
/// 于是助手回报停止失败、App 下次开 TUN 又撞 `kernel already running`。
/// 认领来的孤儿内核不是本进程的子进程，waitpid 返回 -1，回退到 kill(pid, 0) 判定。
func kernelIsAlive(_ pid: Int32) -> Bool {
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { return false }
    return kill(pid, 0) == 0
}

/// §1.4 停内核：只对 helper 自己起的 PID 动手，且先验证其命令行确为内置 sing-box。
///
/// 信号必须升级：睡眠唤醒后内核可能丢了 utun 设备进入假死态，SIGINT 杀不掉。
/// 只发 SIGINT 就返回成功的话，进程赖着不走 → 助手仍认为内核在跑 →
/// 下次开 TUN 被 `kernel already running` 顶回来，用户就是"休眠后再也起不来"。
/// 先 SIGINT 给它优雅释放 utun/路由的机会，不走再 SIGTERM，最后 SIGKILL 兜底。
func stopSingBox(pid: Int32, expectedURL: URL) throws {
    guard pid > 1 else { throw HelperError.invalidPID }
    // §1.4 验证进程的可执行路径 == 内置 sing-box 路径，绝不按外部 PID 盲杀。
    let expected = expectedURL.resolvingSymlinksInPath().path
    guard let actual = executablePath(ofPID: pid) else { throw HelperError.processMismatch(pid) }
    guard actual == expected else { throw HelperError.processMismatch(pid) }

    let stopped = HelperKernelTermination.terminate(
        pid: pid,
        isAlive: kernelIsAlive,
        send: { target, signalNumber in kill(target, signalNumber) },
        waitStep: { usleep(100_000) }   // 每级最多等 2 秒（20 × 100ms）
    )
    guard stopped else { throw HelperError.processMismatch(pid) }
}

/// helper 重启（launchd 重装/重载、崩溃、被 bootout）后，上一实例 spawn 的 root sing-box
/// 会被重新挂到 launchd 下继续跑，而 kernelPID 只存在内存 → 新实例既不知道它、也停不掉它，
/// 用户网络被一个 App 再也清理不掉的 root 进程接管（持有 utun/auto_route/被劫持的 DNS）。
///
/// 启动时按"可执行路径 == trust 里钉死的 root-only sing-box"扫一遍现存进程认领回来。
/// §1.4 仍成立：只有 helper 会 exec 这个 root-only 路径，且认领后所有停止仍走
/// `stopSingBox` 的同一路径校验，不接受任何外部传入 PID。
///
/// 认领后再看调用方 App 是否还在：
/// - 还在（重装/重载场景）→ 记回 clientPID，交回 App 的 stop/recover 正常收尾；
/// - 不在（崩溃后残留）→ 立即停掉，不留无人管的 root 内核。
func adoptOrphanKernel() {
    guard let trust = HelperSecurity.loadTrustConfig(),
          let singBox = singBoxURL(from: trust) else { return }
    let singBoxPath = singBox.resolvingSymlinksInPath().path
    guard let orphan = firstPID(withExecutablePath: singBoxPath) else { return }

    let clientPath = URL(fileURLWithPath: trust.clientExecutablePath).resolvingSymlinksInPath().path
    if let clientPID = firstPID(withExecutablePath: clientPath) {
        state.setKernelPID(orphan)
        state.setClientPID(clientPID)
        FileHandle.standardError.write(Data("kongshan-helper: 认领残留内核 PID \(orphan)（App PID \(clientPID) 仍在）\n".utf8))
    } else {
        try? stopSingBox(pid: orphan, expectedURL: singBox)
        FileHandle.standardError.write(Data("kongshan-helper: App 不在，已停掉残留内核 PID \(orphan)\n".utf8))
    }
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

/// 纵深防御：读出 configFD 全部内容（直到 EOF）。调用方读完即可关 FD。
/// 配置可达数百 KB；helper 读完后做白名单校验，再用本地 pipe 喂 sing-box。
/// 返回 nil 表示读失败（FD 异常）。空 Data 视为有效但后续白名单会拒（非 JSON 对象）。
func readAllConfig(fd: Int32) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 16_384)
    while true {
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            read(fd, ptr.baseAddress!, ptr.count)
        }
        if n == 0 { break }       // EOF（App 写完关了写端）
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        data.append(contentsOf: buf[0..<n])
        // 上限 2 MiB（maxFrameBytes 1 MiB 的 2 倍），防异常大配置耗尽内存。
        if data.count > 2 * 1_048_576 { return nil }
    }
    return data
}

/// 收一帧请求（含随帧到达的 SCM_RIGHTS FD）。线缆层与 App 共用 `HelperWire`——
/// 两端各写一份的后果见 HelperWire 的注释（FD 被内核丢弃 → "missing config fd"）。
func recvRequest(connfd: Int32) -> (request: HelperRequest?, configFD: Int32?) {
    let (body, fd) = HelperWire.receive(on: connfd)
    guard let body else { return (nil, nil) }
    guard let request = try? HelperFraming.decode(HelperRequest.self, from: body) else {
        if let fd { close(fd) }   // 解不出请求也要关掉已收到的 fd
        return (nil, nil)
    }
    return (request, fd)
}

/// 发一帧响应。
func sendResponse(_ response: HelperResponse, connfd: Int32) {
    guard let frame = try? HelperFraming.encode(response) else { return }
    try? HelperWire.send(frame: frame, fd: nil, on: connfd)
}

/// 处理一个连接：鉴权 → 收请求 → 决策 → 执行 → 回响应 → 关连接。
/// sing-box 路径与 cdhash 从 trust.json 读（修复 C），不再用 helper 启动时推导的全局 singBox。
func handleConnection(connfd: Int32) {
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
    // 加固（finding3）：收到的 configFD 由本函数持有，任何路径（解析失败 / 非 startKernel /
    // startSingBox 抛错 / 成功）结束时都关闭，避免 fd 泄漏。startSingBox 只借它做 dup2，不自关。
    defer { if let fd = configFD, fd >= 0 { close(fd) } }
    guard let request else { return }  // 解析失败 → 断连。

    // 修复 C：sing-box 路径从 trust 读。trust 缺路径 → startTun/stopTun 都做不了。
    guard let singBox = singBoxURL(from: trust) else {
        sendResponse(HelperResponse(ok: false, message: "sing-box path not configured", helperVersion: helperVersion), connfd: connfd)
        return
    }

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
        // 纵深防御：先读出配置做白名单校验，再喂 sing-box。防 App 被攻破后塞武器化配置
        // （如 clash_api 远控 root sing-box）。configFD 由外层 defer 关闭，这里只读。
        guard let configData = readAllConfig(fd: fd) else {
            sendResponse(HelperResponse(ok: false, message: "config read failed", helperVersion: helperVersion), connfd: connfd)
            return
        }
        let validation = HelperConfigWhitelist.validate(configData)
        guard validation.ok, let sanitizedConfig = validation.sanitizedData else {
            sendResponse(HelperResponse(ok: false, message: "config rejected: \(validation.reason ?? "unknown")", helperVersion: helperVersion), connfd: connfd)
            return
        }
        do {
            let pid = try startSingBox(at: singBox, configData: sanitizedConfig, pinnedCDHashHex: trust.singBoxCDHashHex)
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
/// sing-box 路径从 trust.json 读（修复 C），与 handleConnection 同源。
func checkClientLiveness() {
    let kernelPID = state.kernelPIDValue()
    guard kernelPID > 0 else { return }
    let clientPID = state.clientPIDValue()
    guard clientPID > 0 else { return }
    // kill(pid, 0) 只检查进程存在（不发信号）。
    if kill(clientPID, 0) != 0 {
        // App 不在了，停自己起的内核。
        guard let trust = HelperSecurity.loadTrustConfig(),
              let singBox = singBoxURL(from: trust) else { return }
        let pid = state.clearKernelPID()
        do {
            try stopSingBox(pid: pid, expectedURL: singBox)
            state.setClientPID(0)   // 内核已停，调用方记录一并作废
        } catch {
            // **停失败必须把 PID 记回**（与 stopKernel 分支一致）。
            // 清掉了就等于助手从此不认识这个仍在运行的内核：status 会报告"没有内核在跑"，
            // App 下次启动便会再起一个 → 两个 root 内核同时接管网络，比残留一个更糟。
            state.setKernelPID(pid)
            FileHandle.standardError.write(Data("kongshan-helper: 自愈停内核失败，保留 PID \(pid) 下轮重试\n".utf8))
        }
    }
}

/// 启动前若日志超限，截断保留尾部，防无限增长。
func rotateLogIfNeeded() {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
          let size = attrs[.size] as? NSNumber, size.intValue > logByteLimit else { return }
    guard let data = try? Data(contentsOf: logURL) else { return }
    let tail = data.suffix(logByteLimit / 5)  // 保留约 1MB 尾部

    // **必须原地截断，不能用原子写替换**。原子写换的是 inode：helper 重启时若有
    // 认领回来的内核仍在运行，它持有旧 inode 的 O_APPEND fd，之后所有日志都会写进
    // 那个已被 unlink 的文件——表现为"内核明明在跑，日志文件却一直是空的/不增长"，
    // 排查时极具误导性（本项目就被这个坑过一次）。
    // 原地 ftruncate + 覆写让 inode 保持不变，运行中内核的 fd 继续有效。
    let fd = open(logURL.path, O_WRONLY | O_CLOEXEC)
    guard fd >= 0 else { return }
    defer { close(fd) }
    guard ftruncate(fd, 0) == 0 else { return }
    _ = tail.withUnsafeBytes { ptr -> Int in
        guard let base = ptr.baseAddress else { return 0 }
        var offset = 0
        while offset < ptr.count {
            let n = pwrite(fd, base.advanced(by: offset), ptr.count - offset, off_t(offset))
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            offset += n
        }
        return offset
    }
    try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: logURL.path)
}

// MARK: - socket 服务（§2b.1）

/// §2b.1 建立 Unix domain socket。
///
/// 权限（修复 A）：目录 `0711` root 拥有（others 可穿越、不可列），socket `0666`（others 可连）。
/// 安全主防线是 §5.1 audit_token 对端校验，从不依赖 socket 文件权限——设计本就假设
/// "同用户任意进程都能连"。但目录必须 root 拥有且非 world-writable，否则攻击者可 unlink
/// socket 再 bind 假 helper 做骗连（socket-squatting，虽拿不到 root，但避免）。
func setupSocket() -> Int32 {
    // stateDirectory 及其父 .../kongshan 都设 0711 root（修复 A，常量见 HelperConstants）。
    // mkdir -p 等价：从最深已有祖先向下建，每层 chmod 0711。
    let dirMode = mode_t(HelperConstants.socketDirectoryMode)
    _ = mkdir(HelperConstants.stateDirectory, dirMode)
    chmod(HelperConstants.stateDirectory, dirMode)
    // 父目录 .../kongshan。installer 也会 chmod 它，这里 helper 启动时兜底。
    let parent = (HelperConstants.stateDirectory as NSString).deletingLastPathComponent
    chmod(parent, dirMode)

    // 清掉可能残留的旧 socket 文件。
    unlink(HelperConstants.socketPath)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    // CLOEXEC：否则 posix_spawn 起的 root sing-box 会继承 helper 的监听 socket，
    // helper 退出后这个 socket 仍被内核进程握着。控制面 fd 绝不该流进被管理的进程。
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

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

    // socket 0666：others 可连（App 普通用户进程）。主防线是 §5.1 身份校验。
    chmod(HelperConstants.socketPath, mode_t(HelperConstants.socketFileMode))
    guard listen(fd, 5) == 0 else { close(fd); return -1 }
    return fd
}

/// 优雅退出：停内核（若在跑）、关 socket、unlink socket 文件。
/// 修复 C：sing-box 路径从 trust.json 读（与 handleConnection/checkClientLiveness 同源）。
/// trust 缺失/损坏时无法验证 PID 身份 → §1.4 拒绝优先，不盲杀（宁可残留也不杀错）。
func shutdownHelper(listenFD: Int32) {
    let pid = state.clearKernelPID()
    if pid > 0, let trust = HelperSecurity.loadTrustConfig(),
       let singBox = singBoxURL(from: trust) {
        try? stopSingBox(pid: pid, expectedURL: singBox)
    }
    shutdown(listenFD, Int32(SHUT_RDWR))
    close(listenFD)
    unlink(HelperConstants.socketPath)
}

// MARK: - 入口

// 信任配置加载：缺失、损坏或旧 schema 一律拒绝，App 的 status 自检会触发重装提示。
enum HelperSecurity {
    static func loadTrustConfig() -> HelperTrustConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: HelperConstants.trustConfigPath)) else {
            return nil
        }
        guard let trust = try? JSONDecoder().decode(HelperTrustConfig.self, from: data),
              trust.isCurrent else {
            return nil
        }
        return trust
    }
}

// 修复 C：helper 不再在启动时推导 sing-box 路径（singBoxURL() 无参版已移除）。
// sing-box 路径改在每次连接时从 trust.json 读（handleConnection/checkClientLiveness/shutdownHelper）。
// 这样 helper 被拷到 root-only 位置后不依赖相对路径；trust 缺 singBoxExecutablePath 时
// startTun/stopTun 会回报错误（拒绝优先），status 仍需通过身份校验——trust 缺失则全部拒绝。
rotateLogIfNeeded()
// 重启/重装/崩溃后先认领或清掉上一实例遗留的 root 内核，再开始服务。
adoptOrphanKernel()

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
livenessTimer.setEventHandler {
    checkClientLiveness()
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
            // 同上：与 App 的这条连接也不能被 sing-box 继承。
            _ = fcntl(connfd, F_SETFD, FD_CLOEXEC)
            handleConnection(connfd: connfd)
        }
    } else if n < 0 && errno != EINTR {
        break
    }
}

shutdownHelper(listenFD: listenFD)
FileHandle.standardError.write(Data("kongshan-helper: 已退出。\n".utf8))
exit(EXIT_SUCCESS)
