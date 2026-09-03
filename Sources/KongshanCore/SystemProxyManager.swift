import Foundation

public struct NetworkSetupCommand: Equatable, Sendable {
    public let arguments: [String]

    public init(arguments: [String]) {
        self.arguments = arguments
    }
}

public struct ProxyEndpointState: Codable, Equatable, Sendable {
    public let enabled: Bool
    public let server: String
    public let port: Int

    public init(enabled: Bool, server: String, port: Int) {
        self.enabled = enabled
        self.server = server
        self.port = port
    }
}

public struct NetworkServiceProxySnapshot: Codable, Equatable, Sendable {
    public let name: String
    public let http: ProxyEndpointState
    public let https: ProxyEndpointState
    public let socks: ProxyEndpointState
    public let bypassDomains: [String]

    public init(
        name: String,
        http: ProxyEndpointState,
        https: ProxyEndpointState,
        socks: ProxyEndpointState,
        bypassDomains: [String]
    ) {
        self.name = name
        self.http = http
        self.https = https
        self.socks = socks
        self.bypassDomains = bypassDomains
    }
}

public struct ProxyRecoverySnapshot: Codable, Equatable, Sendable {
    public let version: Int
    public let capturedAt: Date
    public let services: [NetworkServiceProxySnapshot]

    public init(version: Int = 1, capturedAt: Date = Date(), services: [NetworkServiceProxySnapshot]) {
        self.version = version
        self.capturedAt = capturedAt
        self.services = services
    }
}

/// 还原结果。`pending` 是快照里此刻不在网络服务列表中的服务：VPN 类虚拟服务
/// （真机 2026-09-03 的「Shadowrocket」）随其 App 启停出现/消失，它们的代理设置这会儿写不回去，
/// 但也不是失败——快照保留，服务重新出现时（重开 App / 换网）自动复位。
/// 旧实现直接跳过这些服务并删掉快照，残留的代理指向已停的中转端口，用户关了代理仍全网走空。
public struct ProxyRestoreOutcome: Equatable, Sendable {
    public let restored: [String]
    public let pending: [String]

    public init(restored: [String], pending: [String]) {
        self.restored = restored
        self.pending = pending
    }
}

public enum SystemProxyError: Error, Equatable, LocalizedError {
    case invalidPort
    case noEnabledServices
    case invalidProxyState(String)
    case noActiveProxySession
    case transactionInProgress
    case unsupportedSnapshotVersion(Int)
    case commandFailed(exitCode: Int32, message: String)
    case rollbackFailed(enableError: String, restoreError: String)

    public var errorDescription: String? {
        switch self {
        case .invalidPort:
            "系统代理端口无效"
        case .noEnabledServices:
            "没有可用的网络服务"
        case let .invalidProxyState(message):
            "无法读取系统代理状态：\(message)"
        case .noActiveProxySession:
            "系统代理尚未启用，无法更新绕过列表"
        case .transactionInProgress:
            "另一项系统代理操作仍在执行"
        case let .unsupportedSnapshotVersion(version):
            "不支持的系统代理恢复快照版本：\(version)"
        case let .commandFailed(exitCode, message):
            "networksetup 执行失败（\(exitCode)）：\(message)"
        case let .rollbackFailed(enableError, restoreError):
            "启用系统代理失败且自动恢复失败：\(enableError)；\(restoreError)"
        }
    }
}

public enum SystemProxyCommands {
    /// 恢复时要包含已禁用服务；networksetup 用前导 `*` 标记禁用，但服务仍存在且可能残留设置。
    public static func allServices(from output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("An asterisk (*)") else { return nil }
            if line.hasPrefix("*") {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespaces)
            }
            return line.isEmpty ? nil : line
        }
    }

    public static func enabledServices(from output: String) -> [String] {
        output.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("An asterisk (*)"),
                  !line.hasPrefix("*") else {
                return nil
            }
            return line
        }
    }

    public static func proxyState(from output: String) throws -> ProxyEndpointState {
        var fields: [String: String] = [:]
        for rawLine in output.components(separatedBy: .newlines) {
            let parts = rawLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            fields[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }

        guard let enabledValue = fields["Enabled"]?.lowercased(),
              ["yes", "no"].contains(enabledValue),
              let portValue = fields["Port"],
              let port = Int(portValue) else {
            throw SystemProxyError.invalidProxyState(output)
        }
        let state = ProxyEndpointState(
            enabled: enabledValue == "yes",
            server: fields["Server"] ?? "",
            port: port
        )
        if state.enabled && (state.server.isEmpty || !(1...65_535).contains(state.port)) {
            throw SystemProxyError.invalidProxyState(output)
        }
        return state
    }

    public static func bypassDomains(from output: String) -> [String] {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.contains(where: {
            $0.localizedCaseInsensitiveContains("aren't any bypass domains")
                || $0.localizedCaseInsensitiveContains("no bypass domains")
        }) else {
            return []
        }
        return lines
    }

    public static func enable(
        services: [String],
        port: Int,
        bypassDomains: [String]? = nil
    ) -> [NetworkSetupCommand] {
        services.flatMap { service in
            var commands = [
                command("-setwebproxy", service, "127.0.0.1", String(port)),
                command("-setwebproxystate", service, "on"),
                command("-setsecurewebproxy", service, "127.0.0.1", String(port)),
                command("-setsecurewebproxystate", service, "on"),
                command("-setsocksfirewallproxy", service, "127.0.0.1", String(port)),
                command("-setsocksfirewallproxystate", service, "on")
            ]
            if let bypassDomains {
                commands.append(bypassCommand(service: service, domains: bypassDomains))
            }
            return commands
        }
    }

    /// 残留清扫用：只关掉指向我们的那几项端点，用户自己配的其它代理（企业 HTTPS 代理等）不动。
    public static func disable(
        service: String,
        http: Bool,
        https: Bool,
        socks: Bool
    ) -> [NetworkSetupCommand] {
        var commands: [NetworkSetupCommand] = []
        if http { commands.append(command("-setwebproxystate", service, "off")) }
        if https { commands.append(command("-setsecurewebproxystate", service, "off")) }
        if socks { commands.append(command("-setsocksfirewallproxystate", service, "off")) }
        return commands
    }

    public static func restore(snapshot: ProxyRecoverySnapshot) -> [NetworkSetupCommand] {
        snapshot.services.flatMap { service in
            restoreEndpoint(
                service: service.name,
                state: service.http,
                setter: "-setwebproxy",
                stateSetter: "-setwebproxystate"
            ) + restoreEndpoint(
                service: service.name,
                state: service.https,
                setter: "-setsecurewebproxy",
                stateSetter: "-setsecurewebproxystate"
            ) + restoreEndpoint(
                service: service.name,
                state: service.socks,
                setter: "-setsocksfirewallproxy",
                stateSetter: "-setsocksfirewallproxystate"
            ) + [bypassCommand(service: service.name, domains: service.bypassDomains)]
        }
    }

    public static func updateBypass(
        services: [String],
        domains: [String]
    ) -> [NetworkSetupCommand] {
        services.map { bypassCommand(service: $0, domains: domains) }
    }

    private static func restoreEndpoint(
        service: String,
        state: ProxyEndpointState,
        setter: String,
        stateSetter: String
    ) -> [NetworkSetupCommand] {
        var commands: [NetworkSetupCommand] = []
        if !state.server.isEmpty, (1...65_535).contains(state.port) {
            commands.append(command(setter, service, state.server, String(state.port)))
        }
        commands.append(command(stateSetter, service, state.enabled ? "on" : "off"))
        return commands
    }

    private static func bypassCommand(service: String, domains: [String]) -> NetworkSetupCommand {
        command("-setproxybypassdomains", service, contentsOf: domains.isEmpty ? ["Empty"] : domains)
    }

    private static func command(_ first: String, _ rest: String...) -> NetworkSetupCommand {
        NetworkSetupCommand(arguments: [first] + rest)
    }

    private static func command(
        _ first: String,
        _ second: String,
        contentsOf rest: [String]
    ) -> NetworkSetupCommand {
        NetworkSetupCommand(arguments: [first, second] + rest)
    }
}

public typealias NetworkSetupRunner = @Sendable (
    _ arguments: [String],
    _ timeout: TimeInterval
) async throws -> ProcessResult

public actor SystemProxyManager {
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
        recoveryURL = storage.rootDirectory.appending(path: "proxy-recovery.json")
    }

    public func enable(port: Int, bypassDomains: [String]? = nil) async throws {
        guard (1...65_535).contains(port) else { throw SystemProxyError.invalidPort }
        try beginTransaction()
        defer { transactionInProgress = false }

        // 上次的快照还在：先把能还原的还原掉。只剩「服务此刻不在列表里」的待还原项时不能拒绝
        // 启用——那会让用户永远开不了代理；把它们带进本次快照，服务回来时照样复位。
        // 真有还原失败（服务在、写不回去）才拒绝，错误原样抛出，用户能看到是哪个服务。
        var carried: [NetworkServiceProxySnapshot] = []
        if try await storage.readIfPresent(from: recoveryURL) != nil {
            let outcome = try await restoreFromDisk()
            if !outcome.pending.isEmpty, let data = try await storage.readIfPresent(from: recoveryURL) {
                carried = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: data).services
            }
        }
        try await storage.prepare()

        let services = SystemProxyCommands.enabledServices(
            from: try await execute(["-listallnetworkservices"]).stdout
        )
        guard !services.isEmpty else { throw SystemProxyError.noEnabledServices }

        var serviceSnapshots: [NetworkServiceProxySnapshot] = []
        for service in services {
            serviceSnapshots.append(try await capture(service: service))
        }
        for entry in carried where !serviceSnapshots.contains(where: { $0.name == entry.name }) {
            serviceSnapshots.append(entry)
        }
        let snapshot = ProxyRecoverySnapshot(services: serviceSnapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await storage.writeAtomically(try encoder.encode(snapshot), to: recoveryURL)
        try await storage.writeAtomically(Data("1".utf8), to: takeoverMarkerURL)

        do {
            for command in SystemProxyCommands.enable(
                services: services,
                port: port,
                bypassDomains: bypassDomains
            ) {
                _ = try await execute(command.arguments)
            }
        } catch {
            do {
                try await restoreFromDisk()
            } catch let restoreError {
                throw SystemProxyError.rollbackFailed(
                    enableError: error.localizedDescription,
                    restoreError: restoreError.localizedDescription
                )
            }
            throw error
        }
    }

    @discardableResult
    public func restore() async throws -> ProxyRestoreOutcome {
        try beginTransaction()
        defer { transactionInProgress = false }
        return try await restoreFromDisk()
    }

    @discardableResult
    public func recoverIfNeeded() async throws -> ProxyRestoreOutcome {
        try beginTransaction()
        defer { transactionInProgress = false }
        return try await restoreFromDisk()
    }

    /// 不依赖快照的兜底清扫：把所有指向 `127.0.0.1:port`（我们的中转端口）的系统代理端点关掉，
    /// 返回被清理的服务名。快照丢失、服务当时不在列表里被漏掉——这类场景只有按"设置里指向谁"
    /// 来清才兜得住：真机 2026-09-03，「Shadowrocket」服务三项代理仍指向已停的 36815，
    /// 用户关掉代理后所有直连请求被送进空端口（Codex 全 404），设置页却显示代理已关。
    ///
    /// **只能在没有接管系统代理时调用**——接管中调用等于把自己关掉；调用方负责这个判断。
    public func sweepResidue(port: Int) async throws -> [String] {
        guard (1...65_535).contains(port) else { throw SystemProxyError.invalidPort }
        try beginTransaction()
        defer { transactionInProgress = false }
        guard try await storage.readIfPresent(from: takeoverMarkerURL) != nil else { return [] }

        let services = SystemProxyCommands.allServices(
            from: try await execute(["-listallnetworkservices"]).stdout
        )
        var cleared: [String] = []
        for service in services {
            let state = try await capture(service: service)
            let http = Self.pointsAtLoopback(state.http, port: port)
            let https = Self.pointsAtLoopback(state.https, port: port)
            let socks = Self.pointsAtLoopback(state.socks, port: port)
            guard http || https || socks else { continue }
            for command in SystemProxyCommands.disable(service: service, http: http, https: https, socks: socks) {
                _ = try await execute(command.arguments)
            }
            cleared.append(service)
        }
        return cleared
    }

    /// 「这个安装曾接管过系统代理」的持久标记，只写不删。残留只可能出现在接管过的安装上：
    /// 没标记时清扫直接返回、不碰 networksetup——从未开过系统代理的用户不必每次换网白跑一圈，
    /// 测试夹具（临时目录）也不会去动宿主机的真实设置。
    private var takeoverMarkerURL: URL {
        recoveryURL.deletingLastPathComponent().appending(path: "proxy-takeover.marker")
    }

    static func pointsAtLoopback(_ endpoint: ProxyEndpointState, port: Int) -> Bool {
        guard endpoint.enabled, endpoint.port == port else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(endpoint.server.lowercased())
    }

    /// 网络服务集合变化后的补挂：macOS 的代理设置按服务存储，新出现的服务
    /// （新 Wi-Fi、USB 共享、雷雳网桥）不会继承设置，流量会静默直连。
    /// 只处理「新出现或不再指向我们」的服务，先把它们此刻的状态并入快照，
    /// 保证之后还原时一并复位。没有活动快照（未接管）时静默返回。
    public func reassert(port: Int, bypassDomains: [String]? = nil) async throws {
        guard (1...65_535).contains(port) else { throw SystemProxyError.invalidPort }
        try beginTransaction()
        defer { transactionInProgress = false }

        guard let data = try await storage.readIfPresent(from: recoveryURL) else { return }
        let snapshot = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: data)
        guard snapshot.version == 1 else {
            throw SystemProxyError.unsupportedSnapshotVersion(snapshot.version)
        }

        let services = SystemProxyCommands.enabledServices(
            from: try await execute(["-listallnetworkservices"]).stdout
        )
        var stale: [String] = []
        var discovered: [NetworkServiceProxySnapshot] = []
        for service in services {
            let current = try await capture(service: service)
            let pointsToUs = [current.http, current.https, current.socks].allSatisfy {
                $0.enabled && $0.server == "127.0.0.1" && $0.port == port
            }
            guard !pointsToUs else { continue }
            stale.append(service)
            if !snapshot.services.contains(where: { $0.name == service }) {
                discovered.append(current)
            }
        }
        guard !stale.isEmpty else { return }

        let updated = ProxyRecoverySnapshot(
            capturedAt: snapshot.capturedAt,
            services: snapshot.services + discovered
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await storage.writeAtomically(try encoder.encode(updated), to: recoveryURL)
        for command in SystemProxyCommands.enable(
            services: stale,
            port: port,
            bypassDomains: bypassDomains
        ) {
            _ = try await execute(command.arguments)
        }
    }

    public func updateBypassDomains(to domains: [String], rollbackTo oldDomains: [String]) async throws {
        try beginTransaction()
        defer { transactionInProgress = false }

        guard let data = try await storage.readIfPresent(from: recoveryURL) else {
            throw SystemProxyError.noActiveProxySession
        }
        let snapshot = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: data)
        guard snapshot.version == 1 else {
            throw SystemProxyError.unsupportedSnapshotVersion(snapshot.version)
        }
        let services = snapshot.services.map(\.name)

        do {
            for command in SystemProxyCommands.updateBypass(services: services, domains: domains) {
                _ = try await execute(command.arguments)
            }
        } catch {
            do {
                for command in SystemProxyCommands.updateBypass(services: services, domains: oldDomains) {
                    _ = try await execute(command.arguments)
                }
            } catch let restoreError {
                throw SystemProxyError.rollbackFailed(
                    enableError: error.localizedDescription,
                    restoreError: restoreError.localizedDescription
                )
            }
            throw error
        }
    }

    private func beginTransaction() throws {
        guard !transactionInProgress else { throw SystemProxyError.transactionInProgress }
        transactionInProgress = true
    }

    private func capture(service: String) async throws -> NetworkServiceProxySnapshot {
        let http = try SystemProxyCommands.proxyState(
            from: try await execute(["-getwebproxy", service]).stdout
        )
        let https = try SystemProxyCommands.proxyState(
            from: try await execute(["-getsecurewebproxy", service]).stdout
        )
        let socks = try SystemProxyCommands.proxyState(
            from: try await execute(["-getsocksfirewallproxy", service]).stdout
        )
        let bypass = SystemProxyCommands.bypassDomains(
            from: try await execute(["-getproxybypassdomains", service]).stdout
        )
        return NetworkServiceProxySnapshot(
            name: service,
            http: http,
            https: https,
            socks: socks,
            bypassDomains: bypass
        )
    }

    /// 逐个服务写回快照并**读回核对**。快照里此刻不在列表中的服务保留为待还原（见
    /// `ProxyRestoreOutcome.pending`），写回失败或读回不一致的服务也保留并抛错；
    /// 只有全部复位成功才删除快照。
    @discardableResult
    private func restoreFromDisk() async throws -> ProxyRestoreOutcome {
        guard let data = try await storage.readIfPresent(from: recoveryURL) else {
            return ProxyRestoreOutcome(restored: [], pending: [])
        }
        let snapshot = try JSONDecoder().decode(ProxyRecoverySnapshot.self, from: data)
        guard snapshot.version == 1 else {
            throw SystemProxyError.unsupportedSnapshotVersion(snapshot.version)
        }
        // 切网络配置后快照里的服务可能已改名/消失；已禁用的服务仍必须恢复。
        let currentServices = Set(
            SystemProxyCommands.allServices(
                from: try await execute(["-listallnetworkservices"]).stdout
            )
        )
        var failures: [String] = []
        var retained: [NetworkServiceProxySnapshot] = []
        var restored: [String] = []
        var pending: [String] = []
        for service in snapshot.services {
            guard currentServices.contains(service.name) else {
                pending.append(service.name)
                retained.append(service)
                continue
            }
            var serviceFailed = false
            for command in SystemProxyCommands.restore(
                snapshot: ProxyRecoverySnapshot(services: [service])
            ) {
                do {
                    _ = try await execute(command.arguments)
                } catch {
                    serviceFailed = true
                    failures.append("\(service.name)：\(error.localizedDescription)")
                }
            }
            if !serviceFailed {
                // networksetup 返回 0 不等于设置真的落下去了；读回核对，不一致就当没还原。
                do {
                    let actual = try await capture(service: service.name)
                    if let mismatch = Self.restoreMismatch(expected: service, actual: actual) {
                        serviceFailed = true
                        failures.append("\(service.name)：还原后读回仍不一致（\(mismatch)）")
                    }
                } catch {
                    serviceFailed = true
                    failures.append("\(service.name)：还原后无法读回核对：\(error.localizedDescription)")
                }
            }
            if serviceFailed {
                retained.append(service)
            } else {
                restored.append(service.name)
            }
        }

        if retained.isEmpty {
            try FileManager.default.removeItem(at: recoveryURL)
            return ProxyRestoreOutcome(restored: restored, pending: [])
        }
        if retained != snapshot.services {
            let retrySnapshot = ProxyRecoverySnapshot(
                capturedAt: snapshot.capturedAt,
                services: retained
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try await storage.writeAtomically(try encoder.encode(retrySnapshot), to: recoveryURL)
        }
        guard failures.isEmpty else {
            throw SystemProxyError.commandFailed(
                exitCode: -1,
                message: "部分网络服务代理恢复失败，已保留快照重试：\(failures.joined(separator: "；"))"
            )
        }
        return ProxyRestoreOutcome(restored: restored, pending: pending)
    }

    /// 读回核对只看开关与（开着时的）地址端口——bypass 列表的格式化差异不该判成失败，
    /// 而"该关的没关、该指回去的没指回去"正是残留的定义。
    static func restoreMismatch(
        expected: NetworkServiceProxySnapshot,
        actual: NetworkServiceProxySnapshot
    ) -> String? {
        let endpoints: [(String, ProxyEndpointState, ProxyEndpointState)] = [
            ("HTTP", expected.http, actual.http),
            ("HTTPS", expected.https, actual.https),
            ("SOCKS", expected.socks, actual.socks)
        ]
        var problems: [String] = []
        for (label, want, got) in endpoints {
            if want.enabled != got.enabled {
                problems.append("\(label) 应为\(want.enabled ? "开" : "关")，实际\(got.enabled ? "开" : "关")")
            } else if want.enabled, !want.server.isEmpty, want.server != got.server || want.port != got.port {
                problems.append("\(label) 应指向 \(want.server):\(want.port)，实际 \(got.server):\(got.port)")
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: "，")
    }

    /// networksetup 在网络服务列表变动期间会瞬时报
    /// `** Error: Unable to find item in network database.`（exit 8）：服务这一刻查不到，
    /// 几百毫秒后又恢复正常。
    ///
    /// 真机 2026-08-25 07:48（换网 7 分钟后）就是如此——启用系统代理失败，
    /// **回滚里的 `-listallnetworkservices` 也一起失败**，于是系统代理状态一度不确定，
    /// 3 秒内连报两次「当前配置应用失败，已回滚」。
    private static let transientNetworkDatabaseError = "unable to find item in network database"

    /// 只重试上面那一种消息，且次数有限。服务若是真被删掉了，多花约 0.6 秒后照样如实报错——
    /// 不能让「配置错了」被伪装成「网络在抖」。
    private static let retryDelays: [Duration] = [.milliseconds(200), .milliseconds(400)]

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
                throw SystemProxyError.commandFailed(exitCode: result.exitCode, message: message)
            }
            try await Task.sleep(for: Self.retryDelays[attempt])
            attempt += 1
        }
    }
}
