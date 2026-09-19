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

/// 还原结果；`pending` 语义同 `ProxyRestoreOutcome`：快照里此刻不在网络服务列表中的服务，
/// 快照保留，服务重新出现时自动复位。
public struct DNSRestoreOutcome: Equatable, Sendable {
    public let restored: [String]
    public let pending: [String]

    public init(restored: [String], pending: [String]) {
        self.restored = restored
        self.pending = pending
    }
}

public enum SystemDNSError: Error, Equatable, LocalizedError {
    case noEnabledServices
    case transactionInProgress
    case unsupportedSnapshotVersion(Int)
    case commandFailed(exitCode: Int32, message: String)
    case rollbackFailed(enableError: String, restoreError: String)

    public var errorDescription: String? {
        switch self {
        case .noEnabledServices:
            "没有可用的网络服务"
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

        // 同 SystemProxyManager.enable：旧快照先还原，只剩待还原（服务不在列表）项时并入本次快照，
        // 真有还原失败才拒绝接管。
        var carried: [DNSServiceSnapshot] = []
        if try await storage.readIfPresent(from: recoveryURL) != nil {
            let outcome = try await restoreFromDisk()
            if !outcome.pending.isEmpty, let data = try await storage.readIfPresent(from: recoveryURL) {
                carried = try decode(data).services
            }
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
        for entry in carried where !snapshots.contains(where: { $0.name == entry.name }) {
            snapshots.append(entry)
        }
        try await persist(DNSRecoverySnapshot(services: snapshots))
        try await storage.writeAtomically(Data("1".utf8), to: takeoverMarkerURL)

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

    @discardableResult
    public func restore() async throws -> DNSRestoreOutcome {
        try beginTransaction()
        defer { transactionInProgress = false }
        return try await restoreFromDisk()
    }

    @discardableResult
    public func recoverIfNeeded() async throws -> DNSRestoreOutcome {
        try beginTransaction()
        defer { transactionInProgress = false }
        return try await restoreFromDisk()
    }

    /// 不依赖快照的兜底清扫：任何 DNS 列表里还含 `server`（TUN 劫持地址）的服务，把它摘掉，
    /// 用户自己加的其它 DNS 保留；返回被清理的服务名。TUN 已停时残留的劫持地址意味着
    /// 全网解析瘫痪。**只能在没有接管系统 DNS 时调用**，调用方负责这个判断。
    public func sweepResidue(server: String) async throws -> [String] {
        try beginTransaction()
        defer { transactionInProgress = false }
        guard try await storage.readIfPresent(from: takeoverMarkerURL) != nil else { return [] }

        let services = SystemProxyCommands.allServices(
            from: try await execute(["-listallnetworkservices"]).stdout
        )
        var cleared: [String] = []
        for service in services {
            let current = try await capture(service: service).servers
            guard current.contains(server) else { continue }
            let remaining = current.filter { $0 != server }
            _ = try await execute(SystemDNSCommands.set(service: service, servers: remaining))
            cleared.append(service)
        }
        return cleared
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

    /// 「这个安装曾接管过系统 DNS」的持久标记，语义同 `SystemProxyManager.takeoverMarkerURL`。
    private var takeoverMarkerURL: URL {
        recoveryURL.deletingLastPathComponent().appending(path: "dns-takeover.marker")
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

    /// 逐个服务写回快照并**读回核对**；此刻不在列表中的服务保留为待还原，失败/不一致的也保留并抛错；
    /// 只有全部复位成功才删除快照。
    @discardableResult
    private func restoreFromDisk() async throws -> DNSRestoreOutcome {
        guard let data = try await storage.readIfPresent(from: recoveryURL) else {
            return DNSRestoreOutcome(restored: [], pending: [])
        }
        let snapshot = try decode(data)
        // 切网络配置后快照里的服务可能已改名/消失；已禁用的服务仍必须恢复。
        let currentServices = Set(
            SystemProxyCommands.allServices(
                from: try await execute(["-listallnetworkservices"]).stdout
            )
        )
        var failures: [String] = []
        var retained: [DNSServiceSnapshot] = []
        var restored: [String] = []
        var pending: [String] = []
        for service in snapshot.services {
            guard currentServices.contains(service.name) else {
                pending.append(service.name)
                retained.append(service)
                continue
            }
            do {
                _ = try await execute(SystemDNSCommands.set(service: service.name, servers: service.servers))
                // networksetup 返回 0 不等于设置真的落下去了；读回核对，不一致就当没还原。
                let actual = try await capture(service: service.name).servers
                guard actual == service.servers else {
                    failures.append(
                        "\(service.name)：还原后读回仍不一致（应为 \(Self.describe(service.servers))，实际 \(Self.describe(actual))）"
                    )
                    retained.append(service)
                    continue
                }
                restored.append(service.name)
            } catch {
                failures.append("\(service.name)：\(error.localizedDescription)")
                retained.append(service)
            }
        }

        if retained.isEmpty {
            try FileManager.default.removeItem(at: recoveryURL)
            return DNSRestoreOutcome(restored: restored, pending: [])
        }
        if retained != snapshot.services {
            try await persist(DNSRecoverySnapshot(
                capturedAt: snapshot.capturedAt,
                services: retained
            ))
        }
        guard failures.isEmpty else {
            throw SystemDNSError.commandFailed(
                exitCode: -1,
                message: "部分网络服务 DNS 恢复失败，已保留快照重试：\(failures.joined(separator: "；"))"
            )
        }
        return DNSRestoreOutcome(restored: restored, pending: pending)
    }

    private static func describe(_ servers: [String]) -> String {
        servers.isEmpty ? "空（DHCP）" : servers.joined(separator: " ")
    }

    /// 与 `SystemProxyManager` 同一套瞬时错误重试，**必须保持一致**：两者在
    /// `start()` 里前后脚跑（先系统代理、后系统 DNS），撞的是同一段服务列表抖动。
    /// 只给代理加重试的话，DNS 这步就成了下一个失败点，配置照样切不动。
    private static let transientNetworkDatabaseError = "unable to find item in network database"

    /// 有界重试，约 3 秒。服务真被删了照样如实报错，不把「配置错了」伪装成「网络在抖」。
    private static let retryDelays: [Duration] = [
        .milliseconds(200), .milliseconds(400), .milliseconds(800), .milliseconds(1600)
    ]

    private func execute(_ arguments: [String]) async throws -> ProcessResult {
        var attempt = 0
        while true {
            let result = try await runner(arguments, timeout)
            guard result.exitCode != 0 else { return result }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderr
            guard attempt < Self.retryDelays.count,
                  message.lowercased().contains(Self.transientNetworkDatabaseError) else {
                throw SystemDNSError.commandFailed(exitCode: result.exitCode, message: message)
            }
            try await Task.sleep(for: Self.retryDelays[attempt])
            attempt += 1
        }
    }
}
