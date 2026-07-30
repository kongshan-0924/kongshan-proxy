import Darwin
import Foundation
import HelperProtocol
import Security

public struct RuntimeParameters: Equatable, Sendable {
    public let mixedPort: UInt16
    public let clashPort: UInt16
    public let secret: String

    public init(mixedPort: UInt16, clashPort: UInt16, secret: String) {
        self.mixedPort = mixedPort
        self.clashPort = clashPort
        self.secret = secret
    }
}

public enum RuntimeSecretsError: Error, Equatable, LocalizedError {
    case randomGenerationFailed(OSStatus)
    case socketCreationFailed(Int32)
    case noHighPortAvailable

    public var errorDescription: String? {
        switch self {
        case let .randomGenerationFailed(status): "生成运行时 secret 失败（\(status)）"
        case let .socketCreationFailed(code): "创建本地端口探测 socket 失败（errno \(code)）"
        case .noHighPortAvailable: "无法分配 49152 到 65535 范围内的本地端口"
        }
    }
}

public enum RuntimeSecrets {
    public static func secret(byteCount: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw RuntimeSecretsError.randomGenerationFailed(status) }
        return Data(bytes).base64EncodedString()
    }

    /// 分配一个本地高位端口。给了 `preferred` 且它仍可绑定时原样复用。
    ///
    /// 复用的理由：系统代理模式下这个端口会写进系统代理设置，而 Chromium 系客户端
    /// （ChatGPT.app 内嵌的 codex 服务、Chrome）会**缓存**解析到的代理地址。内核一重启
    /// 就换端口的话，它们会继续去打已经死掉的旧端口，表现为反复「正在重新连接」，
    /// 直到自己重新读取系统代理配置才恢复——用户看到的就是"重试好几次才连上"。
    ///
    /// 固定端口不降低安全性：inbound 只监听 127.0.0.1 且本来就无鉴权，端口还会通过
    /// 系统代理设置公开给本机每个 App，随机化在这里从来不是一道边界。
    public static func availableHighPort(preferred: UInt16? = nil) throws -> UInt16 {
        if let preferred,
           HelperConstants.loopbackHighPorts.contains(Int(preferred)),
           bindLoopback(port: preferred) != nil {
            return preferred
        }
        return try kernelChosenHighPort()
    }

    /// 首选端口撞占用时的重试退避。总预算 ~1.5 秒，且只有真撞上才付这个代价。
    public static let defaultPreferredPortRetryDelays: [Duration] = [
        .milliseconds(100),
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(800),
    ]

    /// 和 `availableHighPort(preferred:)` 同样的语义，但首选端口撞占用时**带退避重试**。
    /// 只给需要跨启动稳定的 mixed 端口用；clash_api 端口每次随机，没有复用需求。
    ///
    /// 为什么必须重试：端口池 `49152...65535` 就是 macOS 的临时端口范围本身，首选端口
    /// 随时可能被别的进程的临时连接、或上一个内核尚未回收完的 pcb 短暂占住。只探一次
    /// 就换端口的话，一次**瞬时**冲突会**永久**改写落盘端口——2026-07-30 实机就这样从
    /// 49609 掉到 65408，而事后 49609 是空闲的。端口一变系统代理设置跟着变，
    /// 缓存了代理地址的 Chromium 系客户端又开始反复「正在重新连接」，
    /// 正是复用首选端口本来要根治的症状。所以这里宁可多等一秒也别换端口。
    public static func stableHighPort(
        preferred: UInt16?,
        retryDelays: [Duration] = defaultPreferredPortRetryDelays
    ) async throws -> UInt16 {
        if let preferred, HelperConstants.loopbackHighPorts.contains(Int(preferred)) {
            if bindLoopback(port: preferred) != nil { return preferred }
            for delay in retryDelays {
                try await Task.sleep(for: delay)
                if bindLoopback(port: preferred) != nil { return preferred }
            }
        }
        return try kernelChosenHighPort()
    }

    private static func kernelChosenHighPort() throws -> UInt16 {
        for _ in 0..<16 {
            // 范围与 helper 白名单同源（HelperConstants）：helper 只放行这个区间的
            // mixed/clash_api 端口，两处各自硬编码会漂移成"测试全绿、真机被拒"。
            guard let port = bindLoopback(port: 0) else { continue }
            if HelperConstants.loopbackHighPorts.contains(Int(port)) { return port }
        }
        throw RuntimeSecretsError.noHighPortAvailable
    }

    /// 试绑 127.0.0.1 的指定端口（传 0 让内核挑），成功返回实际端口号，失败返回 nil。
    ///
    /// 必须置 `SO_REUSEADDR`：sing-box 是 Go 写的，`net.Listen` 默认就带这个选项。
    /// 探测端不带的话会比真正的监听端更悲观——内核刚停时旧连接还在 TIME_WAIT，
    /// 裸 bind 会 EADDRINUSE，于是每次重启都被迫另选端口，正好把要修的问题又造回来。
    private static func bindLoopback(port: UInt16) -> UInt16? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr(HelperConstants.loopbackAddress))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }
}
