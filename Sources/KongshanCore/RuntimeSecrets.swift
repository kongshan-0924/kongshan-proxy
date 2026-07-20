import Darwin
import Foundation
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
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

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

            let port = UInt16(bigEndian: address.sin_port)
            if (49_152...65_535).contains(port) { return port }
        }
        throw RuntimeSecretsError.noHighPortAvailable
    }
}
