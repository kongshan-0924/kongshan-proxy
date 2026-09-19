import Foundation
import Darwin

public protocol SSHProxyConfigManaging: Sendable {
    func apply(targets: [SSHProxyTarget], relayPort: UInt16?) async throws
}

public enum SSHProxyConfigError: Error, LocalizedError {
    case missingRelayPort
    case unterminatedManagedBlock
    case symbolicLink(URL)

    public var errorDescription: String? {
        switch self {
        case .missingRelayPort: "SSH 代理规则缺少本地 relay 端口"
        case .unterminatedManagedBlock: "~/.ssh/config 中的空山托管标记不完整，已停止修改"
        case let .symbolicLink(url): "SSH 配置路径是符号链接，为避免覆盖链接目标已停止修改：\(url.path)"
        }
    }
}

/// 只管理 OpenSSH 主配置顶部的 Include 标记和独立规则文件。
/// 用户原有 Host/Match 块不参与解析或重排；标记异常时 fail-closed。
public actor SSHProxyConfigManager: SSHProxyConfigManaging {
    public static let blockStart = "# >>> kongshan SSH proxy >>>"
    public static let blockEnd = "# <<< kongshan SSH proxy <<<"
    public static let includeLine = "Include ~/.ssh/kongshan-proxy.conf"

    private let fileManager: FileManager
    private let sshDirectory: URL
    private let configURL: URL
    private let managedURL: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        sshDirectory = homeDirectory.appending(path: ".ssh", directoryHint: .isDirectory)
        configURL = sshDirectory.appending(path: "config")
        managedURL = sshDirectory.appending(path: "kongshan-proxy.conf")
    }

    public func apply(targets: [SSHProxyTarget], relayPort: UInt16?) async throws {
        let validated = try targets.map { try $0.validated() }
        if validated.isEmpty {
            try removeManagedConfiguration()
            return
        }
        guard let relayPort else { throw SSHProxyConfigError.missingRelayPort }

        try prepareDirectory()
        try rejectSymbolicLink(managedURL)
        try rejectSymbolicLink(configURL)

        let existing = fileManager.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""
        let stripped = try Self.removingManagedBlock(from: existing)
        let block = "\(Self.blockStart)\n\(Self.includeLine)\n\(Self.blockEnd)"
        let updated = stripped.isEmpty ? "\(block)\n" : "\(block)\n\n\(stripped)"
        let managedSnapshot = try snapshot(managedURL)
        let configSnapshot = try snapshot(configURL)
        do {
            try writeAtomically(Self.managedConfiguration(targets: validated, relayPort: relayPort), to: managedURL)
            try writeAtomically(updated, to: configURL)
        } catch {
            try? restore(managedSnapshot, to: managedURL)
            try? restore(configSnapshot, to: configURL)
            throw error
        }
    }

    public static func managedConfiguration(targets: [SSHProxyTarget], relayPort: UInt16) -> String {
        let blocks = targets.sorted { lhs, rhs in
            lhs.address == rhs.address ? lhs.port < rhs.port : lhs.address < rhs.address
        }.map { target in
            """
            Match host \(target.address) exec "/bin/test %p = \(target.port)"
                ProxyCommand /usr/bin/nc -x 127.0.0.1:\(relayPort) -X 5 %h %p
            Match all
            """
        }
        return (["# Managed by kongshan. Changes are replaced when SSH proxy targets are updated."] + blocks)
            .joined(separator: "\n") + "\n"
    }

    public static func removingManagedBlock(from config: String) throws -> String {
        let lines = config.components(separatedBy: .newlines)
        var output: [String] = []
        var inside = false
        var foundStart = false
        for line in lines {
            if line == blockStart {
                guard !inside else { throw SSHProxyConfigError.unterminatedManagedBlock }
                inside = true
                foundStart = true
                continue
            }
            if line == blockEnd {
                guard inside else { throw SSHProxyConfigError.unterminatedManagedBlock }
                inside = false
                continue
            }
            if !inside { output.append(line) }
        }
        guard !inside else { throw SSHProxyConfigError.unterminatedManagedBlock }
        guard foundStart else { return config }

        while output.first?.isEmpty == true { output.removeFirst() }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
    }

    private func removeManagedConfiguration() throws {
        // fail-closed 只该拦住“确实留下了托管内容、却无法安全移除”的情况。没写过就没得清，
        // 必须是无操作：否则把 ~/.ssh/config 软链到 dotfiles 仓库、从没用过本功能的用户，
        // 每次停止代理、应用分流规则、甚至每次启动都会被这条检查拖出一条失败。
        guard hasManagedFootprint() else { return }
        try rejectSymbolicLink(sshDirectory)
        try rejectSymbolicLink(configURL)
        try rejectSymbolicLink(managedURL)
        let configSnapshot = try snapshot(configURL)
        let managedSnapshot = try snapshot(managedURL)
        let existing = configSnapshot.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let updated = try Self.removingManagedBlock(from: existing)
        do {
            if configSnapshot != nil, updated != existing {
                try writeAtomically(updated, to: configURL)
            }
            if managedSnapshot != nil { try fileManager.removeItem(at: managedURL) }
        } catch {
            try? restore(configSnapshot, to: configURL)
            try? restore(managedSnapshot, to: managedURL)
            throw error
        }
    }

    /// 只读判断是否留下过托管痕迹，不写任何文件。主配置存在却读不出来时按“有痕迹”处理，
    /// 让后续的符号链接检查继续 fail-closed，而不是当成干净状态放过。
    private func hasManagedFootprint() -> Bool {
        if fileManager.fileExists(atPath: managedURL.path) { return true }
        guard fileManager.fileExists(atPath: configURL.path) else { return false }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return true }
        return text.contains(Self.blockStart) || text.contains(Self.blockEnd)
    }

    private func prepareDirectory() throws {
        try rejectSymbolicLink(sshDirectory)
        try fileManager.createDirectory(
            at: sshDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: sshDirectory.path
        )
    }

    private func writeAtomically(_ string: String, to url: URL) throws {
        try prepareDirectory()
        try Data(string.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func rejectSymbolicLink(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            if errno == ENOENT { return }
            throw CocoaError(.fileReadUnknown)
        }
        if (metadata.st_mode & S_IFMT) == S_IFLNK {
            throw SSHProxyConfigError.symbolicLink(url)
        }
    }

    private func snapshot(_ url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    private func restore(_ data: Data?, to url: URL) throws {
        if let data {
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: url.path
            )
        } else if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

public actor InertSSHProxyConfigManager: SSHProxyConfigManaging {
    public init() {}
    public func apply(targets _: [SSHProxyTarget], relayPort _: UInt16?) async throws {}
}
