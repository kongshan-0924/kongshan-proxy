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
        for command in SystemProxyCommands.restore(snapshot: snapshot) {
            _ = try await execute(command.arguments)
        }
        try FileManager.default.removeItem(at: recoveryURL)
    }

    private func execute(_ arguments: [String]) async throws -> ProcessResult {
        let result = try await runner(arguments, timeout)
        guard result.exitCode == 0 else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SystemProxyError.commandFailed(
                exitCode: result.exitCode,
                message: message.isEmpty ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : message
            )
        }
        return result
    }
}
