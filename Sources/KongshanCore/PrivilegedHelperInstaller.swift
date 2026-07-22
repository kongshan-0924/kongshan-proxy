import Foundation
import HelperProtocol
import Security

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

    /// .app 内内置 sing-box 位置（Contents/Resources/sing-box）。
    /// 修复 C：安装时算它的 cdhash 钉死，并把绝对路径写进 trust.json。
    public static var bundledSingBoxURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Resources/sing-box")
    }

    /// 修复 C：helper 拷到 root-only 位置（stateDirectory/KongshanHelper，root:wheel 0755）。
    /// plist 的 ProgramArguments 指向这个拷贝，不再直指 bundle——用户改不动 root-only 拷贝。
    public static var installedHelperURL: URL {
        URL(fileURLWithPath: HelperConstants.stateDirectory + "/KongshanHelper")
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

    /// 安装：一条 osascript 提权完成建目录、拷 helper、写 trust.json、写 plist、bootstrap。
    /// - Parameter authorizer: 执行 appleScript 的提权器（与 PrivilegedLauncher 同源，可注入测试）。
    public static func install(
        authorizer: PrivilegedAuthorizer,
        timeout: TimeInterval = 60
    ) async throws {
        // 修复 C.3：安装前校验 App bundle 不在用户家目录下（家目录可写 = bundle 可被替换 = 提权风险）。
        guard HelperInstallLocation.isAllowed(bundleURL: Bundle.main.bundleURL, homeDirectory: NSHomeDirectory()) else {
            throw PrivilegedLauncherError.authorizationFailed(
                "请把 kongshan.app 移到 /Applications 再安装助手（不支持装在用户家目录）"
            )
        }

        let bundledHelperPath = bundledHelperURL.path
        let clientPath = clientExecutableURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: bundledHelperPath) else {
            throw PrivilegedLauncherError.processInspectionFailed("找不到 .app 内的 KongshanHelper")
        }
        let singBoxPath = bundledSingBoxURL.path
        guard FileManager.default.fileExists(atPath: singBoxPath) else {
            throw PrivilegedLauncherError.processInspectionFailed("找不到 .app 内的 sing-box")
        }

        // 修复 C.2：算 bundle 内 sing-box 的 cdhash，钉死进 trust.json。
        // ad-hoc 签名零成本可伪造，光验"签名有效"挡不住替换；必须钉 cdhash。
        let singBoxCDHashHex = computeCDHashHex(at: bundledSingBoxURL)

        // 修复 C.1：plist 指向 root-only helper 拷贝（用户改不动），不再直指 bundle。
        let installedHelperPath = installedHelperURL.path

        // trust.json：JSONEncoder 结构化生成（修复 C 加 singBox 字段；D1 trust.json 部分在此完成）。
        // 别字符串插值——clientPath/singBoxPath 可能含 JSON 元字符。
        let trustConfig = HelperTrustConfig(
            clientExecutablePath: clientPath,
            pinnedCDHashHex: nil,
            singBoxExecutablePath: singBoxPath,
            singBoxCDHashHex: singBoxCDHashHex
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let trustJSONData = try encoder.encode(trustConfig)
        // base64 传输：二进制安全、无 shell 转义/注入风险。
        let trustBase64 = trustJSONData.base64EncodedString()

        // 修复 D1：plist 用 PropertyListSerialization 结构化生成，别字符串插值——
        // 避免 helper 路径含 XML 元字符时注入 launchd 键。base64 传输（与 trust.json 同）。
        let plistDict: [String: Any] = [
            "Label": HelperConstants.daemonLabel,
            "ProgramArguments": [installedHelperPath],
            "KeepAlive": true,
            "RunAtLoad": true
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        let plistBase64 = plistData.base64EncodedString()

        // 一条 shell 命令完成全部 root 操作。先 bootout 旧实例（若有）再 bootstrap，幂等。
        // 权限（修复 A）：目录 0711（others 可穿越、不可列），socket 0666（others 可连）。
        // trust.json 0600 root（含 cdhash 等钉死值，用户不可读改）。plist 0644。
        // helper 拷贝 0755 root:wheel（用户不可改）。
        let stateDir = HelperConstants.stateDirectory
        let parentDir = (stateDir as NSString).deletingLastPathComponent
        // 修复 A：目录权限用共享常量，与 helper setupSocket 同步（别一处改了另一处漂移）。
        let dirModeOctal = String(HelperConstants.socketDirectoryMode, radix: 8)  // "711"
        let command = [
            "set -e",
            "umask 077",
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            // stateDirectory 及其父 .../kongshan 都建出并显式 chmod 0711（修复 A）。
            "/bin/mkdir -p \(shellQuote(stateDir))",
            "/bin/chmod \(dirModeOctal) \(shellQuote(parentDir))",
            "/bin/chmod \(dirModeOctal) \(shellQuote(stateDir))",
            // 修复 C.1：拷 bundle helper → root-only 位置（先 rm 防旧残留，再 cp + chown + chmod）。
            "/bin/rm -f \(shellQuote(installedHelperPath))",
            "/bin/cp \(shellQuote(bundledHelperPath)) \(shellQuote(installedHelperPath))",
            "/usr/sbin/chown root:wheel \(shellQuote(installedHelperPath))",
            "/bin/chmod 755 \(shellQuote(installedHelperPath))",
            // trust.json：base64 解码写入，root 0600（含钉死的 sing-box cdhash，用户不可读改）。
            "/usr/bin/printf '%s' \(shellQuote(trustBase64)) | /usr/bin/base64 -D > \(shellQuote(HelperConstants.trustConfigPath))",
            "/usr/sbin/chown root:wheel \(shellQuote(HelperConstants.trustConfigPath))",
            "/bin/chmod 600 \(shellQuote(HelperConstants.trustConfigPath))",
            // plist：base64 解码写入，root 0644（launchd 需可读）。
            "/usr/bin/printf '%s' \(shellQuote(plistBase64)) | /usr/bin/base64 -D > \(shellQuote(plistPath))",
            "/usr/sbin/chown root:wheel \(shellQuote(plistPath))",
            "/bin/chmod 644 \(shellQuote(plistPath))",
            // socket 由 helper 自己建（chmod 0666），这里不预建。
            // 先 bootout 旧实例（失败无害），再 bootstrap。
            "/bin/launchctl bootout system/\(HelperConstants.daemonLabel) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(shellQuote(plistPath))"
        ].joined(separator: "; ")

        _ = try await authorizer(appleScript(command: command), timeout)
    }

    /// 修复 C.2：计算二进制的 cdhash（kSecCodeInfoUnique，十六进制小写）。失败返回 nil。
    /// 安装时钉死 sing-box cdhash，防 bundle 内 sing-box 被替换后以 root 执行。
    /// helper exec 前用 HelperSingBoxTrust.isCDHashMatched 校验目标 cdhash == 此值。
    private static func computeCDHashHex(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info else { return nil }
        let dict = info as! [String: Any]
        guard let cdhash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return cdhash.map { String(format: "%02x", $0) }.joined()
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
