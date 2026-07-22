import Foundation

public actor Storage {
    /// 数据目录与其中所有文件的权限。kongshan 在这里持久化订阅 YAML、节点凭据、
    /// Clash API secret 与诊断快照，全部都是敏感数据。同机其他非 root 用户
    /// 不应能读取——0700/0600 与 KernelLogStore、PrivilegedLauncher 保持一致。
    private static let directoryPermissions: NSNumber = NSNumber(value: Int16(0o700))
    private static let filePermissions: NSNumber = NSNumber(value: Int16(0o600))

    public nonisolated let rootDirectory: URL

    public init(rootDirectory: URL = AppIdentity.supportDirectory) {
        self.rootDirectory = rootDirectory
    }

    public nonisolated var subscriptionsDirectory: URL {
        rootDirectory.appending(path: "subscriptions", directoryHint: .isDirectory)
    }

    public nonisolated func cacheURL(for subscription: SubscriptionSource) -> URL {
        subscriptionsDirectory.appending(path: "\(subscription.id.uuidString.lowercased()).yaml")
    }

    public func prepare() throws {
        for directory in [
            rootDirectory,
            subscriptionsDirectory,
            rootDirectory.appending(path: "logs", directoryHint: .isDirectory),
            rootDirectory.appending(path: "rule-sets", directoryHint: .isDirectory)
        ] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
            // createDirectory 在目录已存在时不会改权限，显式 setAttributes 保证即便
            // 上次版本以 0755 建过 rootDirectory，升级后也会被收紧到 0700。
            try FileManager.default.setAttributes(
                [.posixPermissions: Self.directoryPermissions],
                ofItemAtPath: directory.path
            )
        }
    }

    public func writeAtomically(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: Self.directoryPermissions]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.directoryPermissions],
            ofItemAtPath: url.deletingLastPathComponent().path
        )
        try data.write(to: url, options: .atomic)
        // .atomic 用临时文件 + rename，新建文件的权限受 umask 影响（默认 0644），
        // 必须显式收紧到 0600——这是写订阅 YAML / settings.json / config.json 的统一入口。
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: url.path
        )
    }

    public func readIfPresent(from url: URL) throws -> Data? {
        // 直接 try? Data(contentsOf:)：消除 fileExists → Data 之间的 TOCTOU 窗口，
        // 文件被并发删除时返回 nil 而不是抛错，与原语义一致。
        do {
            return try Data(contentsOf: url)
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError else {
                throw error
            }
            return nil
        }
    }
}
