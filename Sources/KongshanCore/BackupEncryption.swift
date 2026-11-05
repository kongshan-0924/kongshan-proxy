import CommonCrypto
import CryptoKit
import Foundation

/// 备份的可选口令加密。备份里有订阅地址与节点凭据，明文导出后放进网盘、发给别人都是泄露面（2026-10-25 审计 S6）。
///
/// 口令经 PBKDF2-SHA256 派生 256 位密钥，AES-GCM 加密整份备份 JSON；外面一层小 JSON 标明格式，
/// 导入时据此认出加密备份。口令错了 GCM 校验失败，不会解出半截数据。
public enum BackupEncryption {
    public static let format = "kongshan-encrypted-backup"
    static let rounds: UInt32 = 600_000

    struct Envelope: Codable {
        let format: String
        let version: Int
        let kdf: String
        let rounds: UInt32
        let salt: Data
        let sealed: Data
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case wrongPassword
        case unsupported
        case keyDerivationFailed

        public var errorDescription: String? {
            switch self {
            case .wrongPassword: "备份口令不对"
            case .unsupported: "不认识的加密备份格式"
            case .keyDerivationFailed: "口令处理失败"
            }
        }
    }

    public static func isEncrypted(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(Envelope.self, from: data))?.format == format
    }

    public static func seal(_ plain: Data, password: String) throws -> Data {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw Failure.keyDerivationFailed }
        let key = try deriveKey(password: password, salt: salt, rounds: rounds)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else { throw Failure.keyDerivationFailed }
        let envelope = Envelope(format: format, version: 1, kdf: "pbkdf2-sha256", rounds: rounds, salt: salt, sealed: sealed)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    public static func open(_ data: Data, password: String) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == format, envelope.version == 1, envelope.kdf == "pbkdf2-sha256",
              (100_000...10_000_000).contains(envelope.rounds) else { throw Failure.unsupported }
        let key = try deriveKey(password: password, salt: envelope.salt, rounds: envelope.rounds)
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key)
        } catch {
            throw Failure.wrongPassword
        }
    }

    static func deriveKey(password: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let passwordBytes = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    passwordBytes.count,
                    saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                    &key, key.count
                )
            }
        }
        guard status == kCCSuccess else { throw Failure.keyDerivationFailed }
        return SymmetricKey(data: key)
    }
}
