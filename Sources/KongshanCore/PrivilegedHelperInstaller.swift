import Foundation
import HelperProtocol

/// 助手安装状态（文件层 + 运行层综合判定）。
public enum HelperInstallStatus: Equatable, Sendable {
    case notInstalled
    case installed
    /// plist 在但助手不可达（App 移动后路径不匹配，或 helper 未跑）。
    case needsReinstall
}

/// 安装/卸载特权助手。所有改系统操作经一条 osascript 提权完成（弹一次密码）。
///
/// 铁律 §1.5：不在自动化里真安装 daemon。install/uninstall 只在用户真机点按钮时触发。
/// plist 模板内联在此（ProgramArguments 指向 .app 内 helper 位置），里程碑 4 负责把 helper
/// 可执行拷进 .app。
public enum PrivilegedHelperInstaller {
    /// LaunchDaemon plist 文件路径。
    public static var plistPath: String {
        "/Library/LaunchDaemons/\(HelperConstants.daemonLabel).plist"
    }

    /// .app 内 helper 可执行位置（Contents/MacOS/KongshanHelper）。
    public static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/KongshanHelper")
    }

    /// App 主可执行路径（写入 trust.json 的 clientExecutablePath）。
    public static var clientExecutableURL: URL {
        Bundle.main.executableURL ?? Bundle.main.bundleURL.appending(path: "Contents/MacOS/kongshan")
    }

    /// plist 是否存在（文件层判定，不依赖 helper 是否在跑）。
    public static func plistExists() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// 综合文件层 + 运行层给出 UI 状态。
    /// - Parameter isReachable: helper socket 是否可连且响应 status（由 PrivilegedHelperClient 判定）。
    public static func currentStatus(isReachable: Bool) -> HelperInstallStatus {
        if !plistExists() { return .notInstalled }
        return isReachable ? .installed : .needsReinstall
    }

    /// 安装：一条 osascript 提权完成建目录、写 trust.json、写 plist、bootstrap。
    /// - Parameter authorizer: 执行 appleScript 的提权器（与 PrivilegedLauncher 同源，可注入测试）。
    public static func install(
        authorizer: PrivilegedAuthorizer,
        timeout: TimeInterval = 60
    ) async throws {
        let helperPath = bundledHelperURL.path
        let clientPath = clientExecutableURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: helperPath) else {
            throw PrivilegedLauncherError.processInspectionFailed("找不到 .app 内的 KongshanHelper")
        }

        let trustJSON = #"{"clientExecutablePath":"\#(clientPath)","pinnedCDHashHex":null}"#
        let plistXML = plistTemplate(helperPath: helperPath)

        // 一条 shell 命令完成全部 root 操作。先 bootout 旧实例（若有）再 bootstrap，幂等。
        // 用 'EOF' heredoc 写文件避免转义；printf 更稳，路径用 shellQuote。
        let command = [
            "set -e",
            "umask 077",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            // stateDirectory：root 0700。
            "/bin/mkdir -p \(shellQuote(HelperConstants.stateDirectory))",
            "/bin/chmod 700 \(shellQuote(HelperConstants.stateDirectory))",
            // trust.json：root 0600。
            "/usr/bin/printf '%s' \(shellQuote(trustJSON)) > \(shellQuote(HelperConstants.trustConfigPath))",
            "/bin/chmod 600 \(shellQuote(HelperConstants.trustConfigPath))",
            // plist：root 0644（launchd 需可读）。
            "/usr/bin/printf '%s' \(shellQuote(plistXML)) > \(shellQuote(plistPath))",
            "/bin/chmod 644 \(shellQuote(plistPath))",
            // 先 bootout 旧实例（失败无害），再 bootstrap。
            "/bin/launchctl bootout system/\(HelperConstants.daemonLabel) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(shellQuote(plistPath))"
        ].joined(separator: "; ")

        _ = try await authorizer(appleScript(command: command), timeout)
    }

    /// 卸载：一条 osascript 提权完成 bootout、删 plist/socket/stateDirectory。
    public static func uninstall(
        authorizer: PrivilegedAuthorizer,
        timeout: TimeInterval = 60
    ) async throws {
        let command = [
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            "/bin/launchctl bootout system/\(HelperConstants.daemonLabel) 2>/dev/null || true",
            "/bin/rm -f \(shellQuote(plistPath))",
            "/bin/rm -f \(shellQuote(HelperConstants.socketPath))",
            "/bin/rm -rf \(shellQuote(HelperConstants.stateDirectory))"
        ].joined(separator: "; ")

        _ = try await authorizer(appleScript(command: command), timeout)
    }

    // MARK: - 内部

    /// LaunchDaemon plist 模板。KeepAlive 让 launchd 在 helper 退出/崩溃时重启；
    /// RunAtLoad 启动时即跑（开机后 helper 自动起，无需 App 先开）。
    private static func plistTemplate(helperPath: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperConstants.daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(helperPath)</string>
            </array>
            <key>KeepAlive</key>
            <true/>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static let prompt = "kongshan 需要管理员权限安装/卸载免密码助手"

    private static func appleScript(command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
    }
}
