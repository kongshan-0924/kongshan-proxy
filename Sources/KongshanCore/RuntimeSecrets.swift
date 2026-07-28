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

    public static func availableHighPort() throws -> UInt16 {
        for _ in 0..<16 {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw RuntimeSecretsError.socketCreationFailed(errno) }
            defer { close(descriptor) }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(0)
            address.sin_addr = in_addr(s_addr: inet_addr(HelperConstants.loopbackAddress))

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { continue }

            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard nameResult == 0 else { continue }

            // 范围与 helper 白名单同源（HelperConstants）：helper 只放行这个区间的
            // mixed/clash_api 端口，两处各自硬编码会漂移成"测试全绿、真机被拒"。
            let port = UInt16(bigEndian: address.sin_port)
            if HelperConstants.loopbackHighPorts.contains(Int(port)) { return port }
        }
        throw RuntimeSecretsError.noHighPortAvailable
    }
}
