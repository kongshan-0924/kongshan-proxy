import Darwin
import Foundation

/// App ↔ 特权助手 的固定标识与路径。改这些要同步改 LaunchDaemon plist 与安装脚本。
public enum HelperConstants {
    /// LaunchDaemon 标签，也是 plist 文件名主体。
    public static let daemonLabel = "com.kaysen.kongshan.helper"
    /// root 拥有、0700 的目录；socket、信任配置都放这里。
    public static let stateDirectory = "/Library/Application Support/kongshan/helper"
    /// Unix domain socket（root 拥有、0600）。长度需 < 104（sun_path 限制）。
    public static let socketPath = stateDirectory + "/helper.sock"
    /// 安装时 root 写入、0600 的信任配置。
    public static let trustConfigPath = stateDirectory + "/trust.json"
    /// helper 允许的调用方代码签名 identifier。
    public static let clientSigningIdentifier = "com.kaysen.kongshan"
    /// 协议版本，App/helper 不匹配时拒绝。
    public static let protocolVersion = 1
    /// 修复 A：socket 目录权限（root 拥有，others 可穿越、不可列）。
    /// helper 的 setupSocket 与 installer 的安装脚本都引用此常量，保证两处同步。
    /// 安全主防线是 §5.1 audit_token 身份校验，从不依赖 socket 权限；但目录必须 root 拥有且
    /// 非 world-writable，防 socket-squatting（攻击者 unlink 再 bind 假 helper 骗连）。
    public static let socketDirectoryMode: Int = 0o711
    /// 修复 A：socket 文件权限（others 可连）。App 是普通用户进程，需可 connect。
    public static let socketFileMode: Int = 0o666
    /// trust.json schema 版本。旧配置解码后 `isCurrent == false`，App 会提示重装。
    /// v3：身份校验改比对 `clientBundlePath`（SecCodeCopyPath 对 bundle 返回 .app 目录），
    /// v2 及更早钉的是主可执行路径，恒不匹配 → 助手实际不可用，必须重装。
    public static let trustConfigVersion: Int = 3
    /// root 内核允许监听的回环地址。
    public static let loopbackAddress = "127.0.0.1"
    /// root 内核允许监听的非特权服务端口区间。
    ///
    /// 必须避开 macOS 默认临时源端口池 49152...65535。mixed 端口需要跨内核重启
    /// 稳定复用；若放在临时池里，旧监听刚释放就可能被任意客户端出站连接短暂抢占，
    /// 导致 TUN/系统代理切换时端口漂移。
    /// App 侧 `RuntimeSecrets.availableHighPort()` 与 helper 侧 `HelperConfigWhitelist`
    /// 都读这里：两处各自硬编码会漂移，真机上表现为 helper 拒配置、TUN 起不来。
    public static let loopbackHighPorts: ClosedRange<Int> = 20_000...49_151
}

/// App → helper 的请求。**刻意不含任意路径/命令字段**——只有固定几个动作，
/// 防止把 helper 变成通用 root 执行器。配置经带外只读 FD 传（不在此结构里）。
public enum HelperRequest: Codable, Sendable, Equatable {
    /// 查询：helper 是否在跑、内核是否已起、版本。
    case status
    /// 起 TUN。配置由 sendmsg 的辅助数据(SCM_RIGHTS)里的只读 FD 提供。
    case startTun
    /// 停 TUN（只停 helper 自己起的那个内核）。
    case stopTun
}

/// helper → App 的响应。
public struct HelperResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String
    public var kernelPID: Int32?
    public var helperVersion: String?

    public init(ok: Bool, message: String = "", kernelPID: Int32? = nil, helperVersion: String? = nil) {
        self.ok = ok
        self.message = message
        self.kernelPID = kernelPID
        self.helperVersion = helperVersion
    }
}

/// 安装时由 root 写入的信任配置：helper 只接受"可执行路径 == 此路径"的调用方，
/// 并钉死 App 与 sing-box 的 cdhash。字段保持可选只为解码旧配置；helper 不会接受不完整配置。
///
/// 修复 C：新增 `singBoxExecutablePath` + `singBoxCDHashHex`——helper exec 的 sing-box
/// 路径与 cdhash 都从这里读（不再从 helper 自身位置相对推导），bundle 内 sing-box 被换也起不来。
public struct HelperTrustConfig: Codable, Sendable, Equatable {
    /// 允许的调用方可执行路径，如 /Applications/kongshan.app/Contents/MacOS/kongshan。
    /// **注意：这不是身份校验用的字段**（见 `clientBundlePath`），只用于安装时算 cdhash 与排错。
    public var clientExecutablePath: String
    /// 身份校验实际比对的路径：App bundle 目录，如 /Applications/kongshan.app。
    ///
    /// 必须是 bundle 而不是主可执行文件——helper 侧的 `SecCodeCopyPath` 对 bundle 型代码
    /// 返回的就是 `.app` 目录。历史上这里钉的是主可执行路径，导致
    /// `identity.executablePath == trust.clientExecutablePath` **永远为假**，
    /// helper 静默拒绝所有连接、App 一直显示"需重装"，免密码助手实际从未生效。
    public var clientBundlePath: String?
    /// 钉死调用方 cdhash（十六进制）。nil 仅表示旧配置。
    public var pinnedCDHashHex: String?
    /// helper exec 的 sing-box 绝对路径（安装时记录 bundle 内 sing-box 位置）。
    /// 修复 C：helper 不再从自身位置相对推导 sing-box，改从 trust.json 读，防 bundle 被移走后路径漂移。
    public var singBoxExecutablePath: String?
    /// 修复 C：钉死 sing-box cdhash（十六进制）。helper exec 前校验目标 sing-box 的 cdhash == 此值，
    /// 不匹配则拒绝启动。bundle 内 sing-box 被替换（ad-hoc 签名零成本）也无法以 root 执行。
    /// nil 仅表示旧配置；新装必填。
    public var singBoxCDHashHex: String?
    /// trust.json schema 版本。nil = 旧 trust.json。
    public var version: Int?

    public init(
        clientExecutablePath: String,
        clientBundlePath: String? = nil,
        pinnedCDHashHex: String? = nil,
        singBoxExecutablePath: String? = nil,
        singBoxCDHashHex: String? = nil,
        version: Int? = HelperConstants.trustConfigVersion
    ) {
        self.clientExecutablePath = clientExecutablePath
        self.clientBundlePath = clientBundlePath
        self.pinnedCDHashHex = pinnedCDHashHex
        self.singBoxExecutablePath = singBoxExecutablePath
        self.singBoxCDHashHex = singBoxCDHashHex
        self.version = version
    }

    /// helper 只接受当前完整 schema。旧配置缺少任一钉死值时必须重装，
    /// 不能继续以“兼容”为由降低 root 执行边界。
    public var isCurrent: Bool {
        version == HelperConstants.trustConfigVersion
            && !clientExecutablePath.isEmpty
            && !(clientBundlePath ?? "").isEmpty
            && !(pinnedCDHashHex ?? "").isEmpty
            && !(singBoxExecutablePath ?? "").isEmpty
            && !(singBoxCDHashHex ?? "").isEmpty
    }
}

/// 一帧消息的编解码：4 字节大端长度前缀 + JSON。用于 socket 上收发请求/响应。
/// （FD 不走这里，走 sendmsg 辅助数据。）
public enum HelperFraming {
    public static let maxFrameBytes = 1 << 20   // 1 MiB 上限，防恶意超大帧

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder().encode(value)
        guard body.count <= maxFrameBytes else { throw HelperFramingError.frameTooLarge }
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return frame
    }

    public static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

public enum HelperFramingError: Error, Equatable {
    case frameTooLarge
    case shortRead
    case sendFailed(String)
}

/// 停内核的信号升级策略。纯逻辑 + 注入的系统调用，便于单测。
///
/// 只发一个 SIGINT 是不够的：内核在睡眠唤醒后丢失 utun 设备时会进入假死态，
/// SIGINT 杀不掉它。进程赖着不走 → 助手认为内核仍在运行 → 下次开 TUN 被
/// `kernel already running` 顶回来，用户表现为"休眠后内核崩了、再也起不来"。
/// 非助手路径（`SingBoxProcess.stop`）本来就有 SIGINT→SIGTERM→SIGKILL 升级，
/// 助手路径必须对齐。
public enum HelperKernelTermination {
    /// 依次尝试 SIGINT → SIGTERM → SIGKILL，每级之间轮询等待进程真正消失。
    /// - Returns: 是否确认进程已退出。
    public static func terminate(
        pid: Int32,
        isAlive: (Int32) -> Bool,
        send: (Int32, Int32) -> Void,
        waitStep: () -> Void,
        stepsPerSignal: Int = 20
    ) -> Bool {
        for signalNumber in [SIGINT, SIGTERM, SIGKILL] {
            guard isAlive(pid) else { return true }
            send(pid, signalNumber)
            for _ in 0..<stepsPerSignal {
                if !isAlive(pid) { return true }
                waitStep()
            }
        }
        return !isAlive(pid)
    }
}

/// App ↔ helper 的线缆层：一帧 = 4 字节大端长度 + JSON body，可随帧附带一个 SCM_RIGHTS FD。
///
/// **两端必须用同一份实现**。这里踩过一个隐蔽的坑：SOCK_STREAM 上辅助数据（SCM_RIGHTS）
/// 是跟着**本次 sendmsg 的第一个字节**投递的。发送端一次 sendmsg 发出「长度前缀+body」，
/// 接收端若先用普通 `read()` 吃掉长度前缀，**内核会把辅助数据连同 FD 直接丢弃并关闭**，
/// 之后再 recvmsg 读 body 永远拿不到 FD → helper 回 "missing config fd"、TUN 起不来。
/// 所以接收端必须用 `recvmsg`（带控制缓冲）来读**长度前缀**。
public enum HelperWire {
    /// 整帧一次 sendmsg 发出（FD 挂在首字节上）；剩余字节按普通写补齐。
    public static func send(frame: Data, fd: Int32?, on socket: Int32) throws {
        try frame.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let base = ptr.baseAddress else { return }
            var sent = 0
            if let fd {
                sent = try sendFirstChunk(socket, body: base, length: ptr.count, fdToSend: fd)
            }
            while sent < ptr.count {
                let n = write(socket, base.advanced(by: sent), ptr.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw HelperFramingError.sendFailed(String(cString: strerror(errno)))
                }
                sent += n
            }
        }
    }

    /// 收一帧。返回 body 与随帧到达的 FD（无则 nil）。任何失败都会关掉已收到的 FD，避免泄漏。
    public static func receive(on socket: Int32) -> (body: Data?, fd: Int32?) {
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        // 关键：用 recvmsg 读长度前缀，FD 就跟在这里。
        let (firstRead, fd) = lengthBytes.withUnsafeMutableBufferPointer { buf in
            receiveFirstChunk(socket, body: buf.baseAddress!, length: 4)
        }
        func fail() -> (Data?, Int32?) {
            if let fd, fd >= 0 { close(fd) }
            return (nil, nil)
        }
        guard firstRead > 0 else { return fail() }
        if firstRead < 4 {
            let rest = lengthBytes.withUnsafeMutableBufferPointer { buf in
                readFully(socket, buf.baseAddress!.advanced(by: firstRead), 4 - firstRead)
            }
            guard rest == 4 - firstRead else { return fail() }
        }

        let length = (Int(lengthBytes[0]) << 24) | (Int(lengthBytes[1]) << 16)
            | (Int(lengthBytes[2]) << 8) | Int(lengthBytes[3])
        guard length > 0, length <= HelperFraming.maxFrameBytes else { return fail() }

        var body = Data(count: length)
        let received = body.withUnsafeMutableBytes { (ptr: UnsafeMutableRawBufferPointer) in
            readFully(socket, ptr.baseAddress!, length)
        }
        guard received == length else { return fail() }
        return (body, fd.flatMap { $0 >= 0 ? $0 : nil })
    }

    // MARK: - 内部

    private static let cmsgSpace = (MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 3) & ~3
    private static let cmsgDataOffset = (MemoryLayout<cmsghdr>.size + 3) & ~3

    private static func sendFirstChunk(
        _ socket: Int32,
        body: UnsafeRawPointer,
        length: Int,
        fdToSend: Int32
    ) throws -> Int {
        var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: body), iov_len: length)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: cmsgSpace,
            alignment: MemoryLayout<Int>.alignment
        )
        memset(buffer.baseAddress, 0, cmsgSpace)
        defer { buffer.deallocate() }

        var msg = msghdr()
        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1
        msg.msg_control = buffer.baseAddress
        msg.msg_controllen = socklen_t(cmsgSpace)

        let cmsg = buffer.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type = SCM_RIGHTS
        cmsg.pointee.cmsg_len = socklen_t(cmsgSpace)
        UnsafeMutableRawPointer(cmsg).advanced(by: cmsgDataOffset)
            .assumingMemoryBound(to: Int32.self).pointee = fdToSend

        let n = sendmsg(socket, &msg, 0)
        guard n >= 0 else {
            throw HelperFramingError.sendFailed(String(cString: strerror(errno)))
        }
        return n
    }

    private static func receiveFirstChunk(
        _ socket: Int32,
        body: UnsafeMutableRawPointer,
        length: Int
    ) -> (received: Int, fd: Int32?) {
        var iov = iovec(iov_base: body, iov_len: length)
        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: cmsgSpace,
            alignment: MemoryLayout<Int>.alignment
        )
        // 清零：防 recvmsg 未填满时把未初始化内存当成 fd。
        memset(buffer.baseAddress, 0, cmsgSpace)
        defer { buffer.deallocate() }

        var msg = msghdr()
        msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
        msg.msg_iovlen = 1
        msg.msg_control = buffer.baseAddress
        msg.msg_controllen = socklen_t(cmsgSpace)

        let n = recvmsg(socket, &msg, 0)
        guard n >= 0 else { return (-1, nil) }

        var fd: Int32 = -1
        let minNeeded = cmsgDataOffset + MemoryLayout<Int32>.size
        if msg.msg_controllen >= socklen_t(minNeeded), let control = msg.msg_control {
            let cmsg = control.assumingMemoryBound(to: cmsghdr.self)
            if cmsg.pointee.cmsg_level == SOL_SOCKET, cmsg.pointee.cmsg_type == SCM_RIGHTS {
                fd = UnsafeMutableRawPointer(cmsg).advanced(by: cmsgDataOffset)
                    .assumingMemoryBound(to: Int32.self).pointee
            }
        }
        // 控制数据被截断（对方塞了多个 fd）→ 不可信：关掉已装入的那个再当作无 fd。
        if (msg.msg_flags & Int32(MSG_CTRUNC)) != 0 {
            if fd >= 0 { close(fd) }
            return (Int(n), nil)
        }
        return (Int(n), fd >= 0 ? fd : nil)
    }

    private static func readFully(_ socket: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var offset = 0
        while offset < count {
            let n = read(socket, buffer.advanced(by: offset), count - offset)
            if n == 0 { return offset }
            if n < 0 {
                if errno == EINTR { continue }
                return -1
            }
            offset += n
        }
        return offset
    }
}

// MARK: - 可注入纯逻辑（便于单测，不依赖系统 API）

/// 对端调用方身份。已从 SecCode 提取好的纯数据，测试可直接构造。
public struct HelperClientIdentity: Equatable, Sendable {
    /// 签名是否有效（未被篡改）。
    public var signatureValid: Bool
    /// 代码签名 identifier，如 "com.kaysen.kongshan"。
    public var signingIdentifier: String?
    /// 可执行文件绝对路径。
    public var executablePath: String?
    /// cdhash（十六进制小写），nil 表示未提取到。
    public var cdHashHex: String?

    public init(signatureValid: Bool, signingIdentifier: String?, executablePath: String?, cdHashHex: String?) {
        self.signatureValid = signatureValid
        self.signingIdentifier = signingIdentifier
        self.executablePath = executablePath
        self.cdHashHex = cdHashHex
    }
}

/// 对端身份判定。纯函数，不依赖 Security.framework / socket。
/// 拒绝优先：任一校验不过即 false。
public enum HelperTrustEvaluation {
    public static func isTrusted(
        identity: HelperClientIdentity,
        trust: HelperTrustConfig,
        expectedIdentifier: String = HelperConstants.clientSigningIdentifier
    ) -> Bool {
        // §1.2 拒绝优先：签名无效直接拒。
        guard identity.signatureValid else { return false }
        // identifier 必须精确匹配（防御深度：SecCode requirement 已校验，这里再兜底）。
        guard identity.signingIdentifier == expectedIdentifier else { return false }
        // §5.1 路径必须 == 安装时钉死的 **bundle** 路径。
        // helper 侧 `SecCodeCopyPath` 对 bundle 型代码返回 `.app` 目录，不是主可执行文件；
        // 拿主可执行路径来比会恒为假（历史 bug，免密码助手因此从未生效）。
        // 拒绝优先：新 schema 必须有 clientBundlePath（`isCurrent` 已强制），缺了直接拒。
        guard let bundlePath = trust.clientBundlePath, !bundlePath.isEmpty,
              identity.executablePath == bundlePath else { return false }
        // §5.1 可选加固：钉 cdhash。pinned 为空字符串也视为不钉。
        if let pinned = trust.pinnedCDHashHex, !pinned.isEmpty {
            guard let actual = identity.cdHashHex,
                  actual.lowercased() == pinned.lowercased() else { return false }
        }
        return true
    }
}

/// 修复 C：sing-box cdhash 钉死判定。纯函数，供 helper exec 前校验 + 单测。
/// 拒绝优先：未钉（nil/空）时返回 true（向后兼容旧 trust.json）；钉了则必须匹配。
public enum HelperSingBoxTrust {
    /// 校验目标 sing-box 的 cdhash 是否与钉死值匹配。
    /// - Parameters:
    ///   - actualCDHashHex: 目标 sing-box 实际 cdhash（SecCodeCopySigningInformation 取 kSecCodeInfoUnique）。nil 表示取不到。
    ///   - pinnedCDHashHex: trust.json 钉死的 cdhash。nil/空 = 未钉（放行，向后兼容）。
    public static func isCDHashMatched(actualCDHashHex: String?, pinnedCDHashHex: String?) -> Bool {
        guard let pinned = pinnedCDHashHex, !pinned.isEmpty else { return true }
        guard let actual = actualCDHashHex else { return false }
        return actual.lowercased() == pinned.lowercased()
    }
}

/// 修复 C.3：安装位置校验。App bundle 不允许在用户家目录（$HOME）下——
/// 家目录对普通用户完全可写，失去"bundle 不可被普通用户改"前提，攻击者无需授权即可替换
/// bundle 内 sing-box/helper。纯函数便于单测。
public enum HelperInstallLocation {
    /// 判定 App bundle 位置是否允许安装特权助手。
    /// - Parameters:
    ///   - bundleURL: App bundle 绝对路径（.app 目录）。
    ///   - homeDirectory: 当前用户家目录绝对路径。
    /// - Returns: bundle 不在家目录之下（且家目录非空）时 true。
    public static func isAllowed(bundleURL: URL, homeDirectory: String) -> Bool {
        // 拒绝优先：家目录为空 → 无法判定，拒绝。
        guard !homeDirectory.isEmpty else { return false }
        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let bundle = bundleURL.standardizedFileURL.path
        if bundle == home { return false }
        if bundle.hasPrefix(home + "/") { return false }
        return true
    }
}

/// helper 对一个请求的执行决策。纯逻辑，FD/进程操作由调用方按决策执行。
public enum HelperRequestDecision: Equatable, Sendable {
    /// 回 status 响应（helper 在跑、版本）。
    case replyStatus
    /// 起内核（调用方持有 configFD，按 §2b.3 执行）。
    case startKernel
    /// 停内核（§2b.4，只停自起的）。
    case stopKernel
    /// 拒绝（未鉴权 / 缺 FD / 状态不对）。
    case reject(message: String)
}

/// 请求分发决策。纯函数，输入鉴权状态/上下文，输出该执行的动作。
public enum HelperDecision {
    public static func decide(
        request: HelperRequest,
        isTrusted: Bool,
        hasConfigFD: Bool,
        kernelRunning: Bool
    ) -> HelperRequestDecision {
        // §1.2 拒绝优先：未鉴权一律拒，连 status 都不回（不泄露任何信息给未鉴权方）。
        guard isTrusted else { return .reject(message: "unauthorized") }
        switch request {
        case .status:
            return .replyStatus
        case .startTun:
            // §1.3 配置必须经 FD 传，无 FD 拒绝。
            guard hasConfigFD else { return .reject(message: "missing config fd") }
            // 已在跑则拒绝，避免双起残留内核。
            if kernelRunning { return .reject(message: "kernel already running") }
            return .startKernel
        case .stopTun:
            // 没在跑的内核没东西可停。
            guard kernelRunning else { return .reject(message: "no kernel running") }
            return .stopKernel
        }
    }
}

/// 配置内容白名单（纵深防御）。helper exec sing-box 前先读出 FD 上的配置做 schema 校验，
/// 拒绝 App 被攻破后塞来的武器化配置（如 `clash_api.external_controller: "0.0.0.0:9090"`
/// 可让攻击者远程无鉴权控制 root sing-box → 改出站/MITM 全部流量）。
///
/// 纯函数，不依赖系统 API，便于单测。除协议类型外还锁死 root 进程的监听面与文件写入面：
/// Clash API 只能监听高位 loopback 端口且必须有 secret；cache_file 路径由 helper
/// 重写到 root 自有目录，不能使用 App 传入的路径。
///
/// **明确不覆盖的范围**（写清楚，别把这里当成"全字段校验"）：`dns`、`route` 与
/// `outbounds[*]`/`inbounds[tun]` 除类型/auto_route 外的字段都只做结构存在性检查。
/// 也就是说 App 被攻破后仍能让 root 内核**读**任意文件（`route.rule_set[].path`、
/// `outbounds[*].tls.certificate_path`）或连任意上游。这是有意的边界：真正的提权面是
/// root **写**文件（`log.output`、`cache_file.path`）与**远程无鉴权控制**（clash_api），
/// 这三处已封死；要扩大覆盖就往 validate 里加分支并同步补测，不要默认"已经全管住了"。
public enum HelperConfigWhitelist {
    /// 允许的代理出站协议类型（与 ConfigGenerator 实际生成的协议对齐）。
    public static let allowedOutboundTypes: Set<String> = [
        "selector", "urltest", "direct", "block",
        "hysteria2", "shadowsocks", "trojan", "vmess", "vless", "anytls"
    ]
    /// 允许的入站类型。mixed=系统代理，tun=TUN 接管。
    public static let allowedInboundTypes: Set<String> = ["mixed", "tun"]

    public struct Result {
        public let ok: Bool
        public let reason: String?
        /// 校验通过后可交给 root sing-box 的配置。cache_file.path 已改为 root 自有路径。
        public let sanitizedData: Data?
    }

    /// 校验并收紧配置字节。失败时不返回可执行配置。
    public static func validate(_ data: Data) -> Result {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return reject("config not a json object")
        }
        let allowedRootKeys: Set<String> = ["log", "dns", "inbounds", "outbounds", "route", "experimental"]
        guard Set(root.keys).isSubset(of: allowedRootKeys) else {
            return reject("unknown top-level key")
        }

        if root["log"] != nil {
            guard let log = root["log"] as? [String: Any] else {
                return reject("log must be an object")
            }
            guard Set(log.keys).isSubset(of: ["level", "timestamp"]), log["output"] == nil else {
                return reject("log output not allowed")
            }
        }
        guard root["dns"] is [String: Any], root["route"] is [String: Any] else {
            return reject("dns and route must be objects")
        }

        guard let outbounds = root["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            return reject("outbounds missing or empty")
        }
        for outbound in outbounds {
            guard let type = outbound["type"] as? String else {
                return reject("outbound missing type")
            }
            guard allowedOutboundTypes.contains(type) else {
                return reject("outbound type not allowed: \(type)")
            }
        }

        guard let inbounds = root["inbounds"] as? [[String: Any]], !inbounds.isEmpty else {
            return reject("inbounds missing or empty")
        }
        var hasTUN = false
        for inbound in inbounds {
            guard let type = inbound["type"] as? String else {
                return reject("inbound missing type")
            }
            guard allowedInboundTypes.contains(type) else {
                return reject("inbound type not allowed: \(type)")
            }
            if type == "tun" {
                hasTUN = true
                guard inbound["auto_route"] as? Bool == true else {
                    return reject("tun auto_route must be enabled")
                }
            } else {
                guard inbound["listen"] as? String == HelperConstants.loopbackAddress,
                      let port = inbound["listen_port"] as? Int,
                      HelperConstants.loopbackHighPorts.contains(port) else {
                    return reject("mixed inbound must use loopback service port")
                }
            }
        }
        guard hasTUN else { return reject("tun inbound required") }

        guard var experimental = root["experimental"] as? [String: Any],
              Set(experimental.keys).isSubset(of: ["clash_api", "cache_file"]),
              let clashAPI = experimental["clash_api"] as? [String: Any],
              Set(clashAPI.keys).isSubset(of: ["external_controller", "secret"]),
              let controller = clashAPI["external_controller"] as? String,
              isLoopbackHighPort(controller),
              let secret = clashAPI["secret"] as? String,
              secret.count >= 16 else {
            return reject("clash_api must use authenticated loopback service port")
        }

        if experimental["cache_file"] != nil {
            guard var cacheFile = experimental["cache_file"] as? [String: Any] else {
                return reject("cache_file must be an object")
            }
            guard Set(cacheFile.keys).isSubset(of: ["enabled", "path", "store_fakeip"]),
                  cacheFile["enabled"] as? Bool == true,
                  cacheFile["store_fakeip"] as? Bool == true else {
                return reject("cache_file shape not allowed")
            }
            cacheFile["path"] = HelperConstants.stateDirectory + "/fakeip-cache-v2.db"
            experimental["cache_file"] = cacheFile
        }
        root["experimental"] = experimental

        guard let sanitized = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        ) else {
            return reject("config serialization failed")
        }
        return Result(ok: true, reason: nil, sanitizedData: sanitized)
    }

    private static func isLoopbackHighPort(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == HelperConstants.loopbackAddress,
              let port = Int(parts[1]), HelperConstants.loopbackHighPorts.contains(port) else {
            return false
        }
        return true
    }

    private static func reject(_ reason: String) -> Result {
        Result(ok: false, reason: reason, sanitizedData: nil)
    }
}
