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

public enum SystemProxyError: Error, Equatable, LocalizedError {
    case invalidPort
    case noEnabledServices
    case invalidProxyState(String)
    case recoveryPending
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
        case .recoveryPending:
            "检测到尚未恢复的系统代理快照"
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

        guard try await storage.readIfPresent(from: recoveryURL) == nil else {
            throw SystemProxyError.recoveryPending
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
        let snapshot = ProxyRecoverySnapshot(services: serviceSnapshots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await storage.writeAtomically(try encoder.encode(snapshot), to: recoveryURL)

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

    private func restoreFromDisk() async throws {
        guard let data = try await storage.readIfPresent(from: recoveryURL) else { return }
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
        var failedServices: [NetworkServiceProxySnapshot] = []
        for service in snapshot.services where currentServices.contains(service.name) {
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
            if serviceFailed { failedServices.append(service) }
        }

        if failedServices.isEmpty {
            try FileManager.default.removeItem(at: recoveryURL)
            return
        }
        let retrySnapshot = ProxyRecoverySnapshot(
            capturedAt: snapshot.capturedAt,
            services: failedServices
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try await storage.writeAtomically(try encoder.encode(retrySnapshot), to: recoveryURL)
        throw SystemProxyError.commandFailed(
            exitCode: -1,
            message: "部分网络服务代理恢复失败，已保留快照重试：\(failures.joined(separator: "；"))"
        )
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
