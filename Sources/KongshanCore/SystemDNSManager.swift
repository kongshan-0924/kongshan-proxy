import Foundation

/// TUN 模式下接管系统 DNS 用的快照与恢复。
///
/// 为什么需要：macOS 的 mDNSResponder 存在 scoped resolver 路径，会把 DNS 查询
/// 直接绑定物理网卡发出、完全绕开 TUN（mihomo#2624 有详细分析）。结果是
/// hijack-dns 抓不到系统解析、污染结果先到。业界通行做法（Clash Verge 等）是
/// 开 TUN 时把每个网络服务的 DNS 指到一个「会被路由进 TUN 的地址」，关闭时还原。
///
/// 结构刻意与 SystemProxyManager 同构：快照先落盘再改系统、失败回滚、
/// 崩溃后下次启动凭恢复文件自愈，事务串行防并发。
public struct DNSServiceSnapshot: Codable, Equatable, Sendable {
    public let name: String
    /// 空数组表示该服务此前没有手动 DNS（跟随 DHCP），还原时写回 "Empty"。
    public let servers: [String]

    public init(name: String, servers: [String]) {
        self.name = name
        self.servers = servers
    }
}

public struct DNSRecoverySnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let capturedAt: Date
    public let services: [DNSServiceSnapshot]

    public init(version: Int = 1, capturedAt: Date = Date(), services: [DNSServiceSnapshot]) {
        self.version = version
        self.capturedAt = capturedAt
        self.services = services
    }
}

public enum SystemDNSError: Error, Equatable, LocalizedError {
    case noEnabledServices
    case recoveryPending
    case transactionInProgress
    case unsupportedSnapshotVersion(Int)
    case commandFailed(exitCode: Int32, message: String)
    case rollbackFailed(enableError: String, restoreError: String)

    public var errorDescription: String? {
        switch self {
        case .noEnabledServices:
            "没有可用的网络服务"
        case .recoveryPending:
            "检测到尚未恢复的系统 DNS 快照"
        case .transactionInProgress:
            "另一项系统 DNS 操作仍在执行"
        case let .unsupportedSnapshotVersion(version):
            "不支持的系统 DNS 恢复快照版本：\(version)"
        case let .commandFailed(exitCode, message):
            "networksetup 执行失败（\(exitCode)）：\(message)"
        case let .rollbackFailed(enableError, restoreError):
            "接管系统 DNS 失败且自动恢复失败：\(enableError)；\(restoreError)"
        }
    }
}

public enum SystemDNSCommands {
    /// `-getdnsservers` 在未手动配置时输出一句英文说明而不是地址列表。
    public static func servers(from output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.contains(where: {
            $0.localizedCaseInsensitiveContains("aren't any DNS Servers")
                || $0.localizedCaseInsensitiveContains("no DNS Servers")
        }) else {
            return []
        }
        return lines
    }

    public static func set(service: String, servers: [String]) -> [String] {
        ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
    }
}

public actor SystemDNSManager {
    public nonisolated let recoveryURL: URL

    private let storage: Storage
    private let runner: NetworkSetupRunner
    private let timeout: TimeInterval
    private var transactionInProgress = false

    /// 真实 networksetup 执行器。**刻意放成命名静态属性，不要内联回默认参数**：
    /// Swift 6 的 debug 构建下，把 async 闭包写成默认参数会在调用它时崩在
    /// `swift_task_dealloc`（EXC_BAD_ACCESS），release 正常。放成静态属性后
    /// debug 也能跑真实路径，单测才能覆盖到真机行为。
    public static let defaultRunner: NetworkSetupRunner = { arguments, timeout in
        try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
            arguments: arguments,
            timeout: timeout
        )
    }

    public init(
        storage: Storage = Storage(),
        timeout: TimeInterval = 5,
        runner: @escaping NetworkSetupRunner = defaultRunner
    ) {
        self.storage = storage
        self.timeout = timeout
        self.runner = runner
        recoveryURL = storage.rootDirectory.appending(path: "dns-recovery.json")
    }

    /// 把所有启用中的网络服务 DNS 指向 `server`（TUN 网段内、会被 hijack-dns 截获的地址）。
    public func enable(server: String) async throws {
        try beginTransaction()
        defer { transactionInProgress = false }

        guard try await storage.readIfPresent(from: recoveryURL) == nil else {
            throw SystemDNSError.recoveryPending
        }
        try await storage.prepare()

        let services = SystemProxyCommands.enabledServices(
            from: try await execute(["-listallnetworkservices"]).stdout
        )
        guard !services.isEmpty else { throw SystemDNSError.noEnabledServices }

        var snapshots: [DNSServiceSnapshot] = []
        for service in services {
            snapshots.append(try await capture(service: service))
        }
        try await persist(DNSRecoverySnapshot(services: snapshots))

        do {
            for service in services {
                _ = try await execute(SystemDNSCommands.set(service: service, servers: [server]))
            }
        } catch {
            do {
                try await restoreFromDisk()
            } catch let restoreError {
                throw SystemDNSError.rollbackFailed(
                    enableError: error.localizedDescription,
                    restoreError: restoreError.localizedDescription
                )
            }
            throw error
        }
    }

    public func restore() async throws {
        try beginTransaction()
        defer { transactionInProgress = false }
        try await restoreFromDisk()
    }

    public func recoverIfNeeded() async throws {
        try beginTransaction()
        defer { transactionInProgress = false }
        try await restoreFromDisk()
    }

    /// 网络服务集合变化后的补挂：只处理「DNS 不再包含我们的 hijack 服务器」的服务，
    /// 把新出现的服务并入快照后再补挂，保证之后还原时一并复位。
    /// 没有活动快照（未接管）时静默返回。
    ///
    /// 关键：补挂不覆盖用户在 session 期间手动加的其它 DNS（如 8.8.8.8）。
    /// 旧实现的 `current.servers != [server]` 判定会在用户加过任何 DNS 后强行改回 `[server]`，
    /// 静默丢失用户的修改。现在分三种情况：
    /// 1. `current == [server]`：用户没动，无需补挂，保留快照原值。
    /// 2. `current` 含 `server` 且有别的服务器：用户加了 DNS → 把加的并入快照（restore 时还原成用户加的），不补挂。
    /// 3. `current` 不含 `server`：hijack 服务器被移除（新服务或被重置）→ 补挂 `[server] + current`，保留用户已有的服务器；
    ///    新服务（不在快照里）才并入快照，已存在快照的保留原值（restore 仍写回原始值）。
    public func reassert(server: String) async throws {
        try beginTransaction()
        defer { transactionInProgress = false }

        guard let data = try await storage.readIfPresent(from: recoveryURL) else { return }
        let snapshot = try decode(data)

        let services = SystemProxyCommands.enabledServices(
            from: try await execute(["-listallnetworkservices"]).stdout
        )
        var stale: [String] = []
        var discovered: [DNSServiceSnapshot] = []
        var refreshedExisting: [DNSServiceSnapshot] = []
        for service in services {
            let current = try await capture(service: service)
            let inSnapshot = snapshot.services.first { $0.name == service }

            if current.servers.contains(server) {
                // 情况 1 / 2：hijack 仍在。
                if current.servers != [server] {
                    // 情况 2：用户在 session 期间加了别的 DNS。把这些并入快照，restore 时还原成用户加的。
                    // 即便该服务不在原快照里，refreshedExisting 的项也只会被 merged 用同名覆盖，
                    // 不在 snapshot.services 里的服务本来就走 discovered 路径或不入快照——这里无副作用。
                    let userAdded = current.servers.filter { $0 != server }
                    refreshedExisting.append(DNSServiceSnapshot(name: service, servers: userAdded))
                }
                // 情况 1：保留快照原值，无需补挂。
                continue
            }

            // 情况 3：hijack 服务器被移除。
            stale.append(service)
            if inSnapshot == nil {
                // 新服务：把当前状态（不含 server）并入快照，restore 时还原到这次的状态。
                discovered.append(DNSServiceSnapshot(name: service, servers: current.servers))
            }
            // 已在快照的服务被重置：保留快照原值（不更新），restore 时仍写回原始值。
        }

        // 合并：snapshot 为基底，refreshedExisting 覆盖同名项（保留用户修改），discovered 追加（新服务）。
        var merged = snapshot.services.map { existing in
            refreshedExisting.first { $0.name == existing.name } ?? existing
        }
        for entry in discovered where !merged.contains(where: { $0.name == entry.name }) {
            merged.append(entry)
        }

        // 即便没有需要补挂的服务，也要持久化合并后的快照（保留用户修改 / 并入新服务）。
        try await persist(DNSRecoverySnapshot(
            capturedAt: snapshot.capturedAt,
            services: merged
        ))
        guard !stale.isEmpty else { return }

        for service in stale {
            // server 放最前；保留用户已有的服务器（current 不含 server，所以直接拼）。
            let existing = try await capture(service: service).servers
            let combined = existing.isEmpty ? [server] : [server] + existing
            _ = try await execute(SystemDNSCommands.set(service: service, servers: combined))
        }
    }

    private func beginTransaction() throws {
        guard !transactionInProgress else { throw SystemDNSError.transactionInProgress }
        transactionInProgress = true
    }

    private func capture(service: String) async throws -> DNSServiceSnapshot {
        DNSServiceSnapshot(
            name: service,
            servers: SystemDNSCommands.servers(
                from: try await execute(["-getdnsservers", service]).stdout
            )
        )
    }

    private func persist(_ snapshot: DNSRecoverySnapshot) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await storage.writeAtomically(try encoder.encode(snapshot), to: recoveryURL)
    }

    private func decode(_ data: Data) throws -> DNSRecoverySnapshot {
        let snapshot = try JSONDecoder().decode(DNSRecoverySnapshot.self, from: data)
        guard snapshot.version == 1 else {
            throw SystemDNSError.unsupportedSnapshotVersion(snapshot.version)
        }
        return snapshot
    }

    private func restoreFromDisk() async throws {
        guard let data = try await storage.readIfPresent(from: recoveryURL) else { return }
        let snapshot = try decode(data)
        // 切网络配置后快照里的服务可能已改名/消失；已禁用的服务仍必须恢复。
        let currentServices = Set(
            SystemProxyCommands.allServices(
                from: try await execute(["-listallnetworkservices"]).stdout
            )
        )
        var failures: [String] = []
        var failedServices: [DNSServiceSnapshot] = []
        for service in snapshot.services where currentServices.contains(service.name) {
            do {
                _ = try await execute(SystemDNSCommands.set(service: service.name, servers: service.servers))
            } catch {
                failures.append("\(service.name)：\(error.localizedDescription)")
                failedServices.append(service)
            }
        }

        if failedServices.isEmpty {
            try FileManager.default.removeItem(at: recoveryURL)
            return
        }
        try await persist(DNSRecoverySnapshot(
            capturedAt: snapshot.capturedAt,
            services: failedServices
        ))
        throw SystemDNSError.commandFailed(
            exitCode: -1,
            message: "部分网络服务 DNS 恢复失败，已保留快照重试：\(failures.joined(separator: "；"))"
        )
    }

    private func execute(_ arguments: [String]) async throws -> ProcessResult {
        let result = try await runner(arguments, timeout)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemDNSError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : message
            )
        }
        return result
    }
}
