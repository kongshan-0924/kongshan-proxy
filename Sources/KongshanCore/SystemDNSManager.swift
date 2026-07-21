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

    public init(
        storage: Storage = Storage(),
        timeout: TimeInterval = 5,
        runner: @escaping NetworkSetupRunner = { arguments, timeout in
            try await ProcessRunner.run(
                executable: URL(fileURLWithPath: "/usr/sbin/networksetup"),
                arguments: arguments,
                timeout: timeout
            )
        }
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

    /// 网络服务集合变化后的补挂：只处理「新出现或 DNS 不再指向我们」的服务，
    /// 把它们此刻的状态并入快照后再覆盖，保证之后还原时一并复位。
    /// 没有活动快照（未接管）时静默返回。
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
        for service in services {
            let current = try await capture(service: service)
            guard current.servers != [server] else { continue }
            stale.append(service)
            if !snapshot.services.contains(where: { $0.name == service }) {
                discovered.append(current)
            }
        }
        guard !stale.isEmpty else { return }

        try await persist(DNSRecoverySnapshot(
            capturedAt: snapshot.capturedAt,
            services: snapshot.services + discovered
        ))
        for service in stale {
            _ = try await execute(SystemDNSCommands.set(service: service, servers: [server]))
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
        for service in snapshot.services {
            _ = try await execute(SystemDNSCommands.set(service: service.name, servers: service.servers))
        }
        try FileManager.default.removeItem(at: recoveryURL)
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
