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
