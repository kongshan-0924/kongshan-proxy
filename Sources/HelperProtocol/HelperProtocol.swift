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
/// （可选）再钉 cdhash。默认不钉 cdhash，避免每次重新构建 App 都要重装。
public struct HelperTrustConfig: Codable, Sendable, Equatable {
    /// 允许的调用方可执行路径，如 /Applications/kongshan.app/Contents/MacOS/kongshan
    public var clientExecutablePath: String
    /// 可选加固：钉死调用方 cdhash（十六进制）。nil = 不钉。
    public var pinnedCDHashHex: String?

    public init(clientExecutablePath: String, pinnedCDHashHex: String? = nil) {
        self.clientExecutablePath = clientExecutablePath
        self.pinnedCDHashHex = pinnedCDHashHex
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
        // §5.1 可执行路径必须 == 安装时钉死的路径。
        guard identity.executablePath == trust.clientExecutablePath else { return false }
        // §5.1 可选加固：钉 cdhash。pinned 为空字符串也视为不钉。
        if let pinned = trust.pinnedCDHashHex, !pinned.isEmpty {
            guard let actual = identity.cdHashHex,
                  actual.lowercased() == pinned.lowercased() else { return false }
        }
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
