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
        // 内容一个字节都没变就别写。这里是全应用唯一的落盘入口，而不少调用方是**定时**
        // 触发的：订阅自动更新每轮都会顺手 `persistSettings()`，内容通常与上次完全相同。
        // 一次 `.atomic` 写要建临时文件 + 写 + rename + 同步元数据（SSD 上是真实的写放大），
        // 而比对旧内容基本命中页缓存。顺带避免无谓的 mtime 变动——代码里没有任何地方
        // 依赖 mtime，但排查问题的人看到 settings.json 一直在变会以为设置刚被改过。
        if let existing = try? Data(contentsOf: url), existing == data {
            try tightenPermissionsIfNeeded(of: url)
            return
        }

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

    /// 内容未变的快路径也必须守住 0600：旧版本可能以 0644 建过这些文件，
    /// 而"跳过写入"不能顺带把收紧权限也跳过去。只在权限确实不对时才动，
    /// 免得快路径又变成每次一次 chmod 系统调用。
    private func tightenPermissionsIfNeeded(of url: URL) throws {
        let current = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        guard current?.int16Value != Self.filePermissions.int16Value else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: Self.filePermissions],
            ofItemAtPath: url.path
        )
    }

    /// 删除某个订阅的缓存 YAML。文件不存在视为成功（幂等）。
    public func removeSubscriptionCache(for subscription: SubscriptionSource) throws {
        do {
            try FileManager.default.removeItem(at: cacheURL(for: subscription))
        } catch {
            let nsError = error as NSError
            guard nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError else {
                throw error
            }
        }
    }

    /// 清掉不再对应任何在册订阅的缓存文件，返回删除的文件名。
    ///
    /// 历史版本删除订阅时不删缓存，真机上曾积累 5 个孤儿共 27 MB（其中两个各 13 MB）；
    /// 即便删除路径修好，删除与落盘之间进程终止也仍会留孤儿，所以启动时兜底清一次。
    /// 只动本目录里「UUID.yaml」形态的文件：目录中若出现别的东西（用户手放的备份、
    /// 未来版本的新文件），一概不碰。
    public func removeOrphanSubscriptionCaches(keeping subscriptions: [SubscriptionSource]) -> [String] {
        let registered = Set(subscriptions.map { $0.id.uuidString.lowercased() })
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: subscriptionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var removed: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".yaml"),
                  let id = UUID(uuidString: String(name.dropLast(".yaml".count))),
                  !registered.contains(id.uuidString.lowercased()) else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removed.append(name)
            } catch {
                continue
            }
        }
        return removed
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
