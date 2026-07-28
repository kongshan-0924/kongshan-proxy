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

    /// 修复 C①：sing-box 也拷到 root-only 位置（stateDirectory/sing-box，root:wheel 0755）。
    /// trust.singBoxExecutablePath 指向这个拷贝，不再指 bundle——否则 verify→exec 之间存在
    /// TOCTOU：bundle 内 sing-box 对 admin 组可写（/Applications），攻击者在校验后、posix_spawn
    /// 前原子替换 → root 执行任意二进制。与 helper 拷贝完全同构（同目录、同权限、同 chown）。
    public static var installedSingBoxURL: URL {
        URL(fileURLWithPath: HelperConstants.stateDirectory + "/sing-box")
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
        // 修复 C②：算不出 cdhash fail-closed（拒绝安装），不静默写 null。
        let singBoxCDHashHex = try requireCDHashHex(at: bundledSingBoxURL)
        // 加固（堵 §5.1 客户端伪造）：钉客户端 App 主可执行 cdhash（fail-closed）。
        // 光验 identifier 挡不住"覆盖主可执行 + codesign -s - -i 同 identifier 重签"；钉 cdhash
        // 让重签因 hash 变化被拒。须配合 build 的 hardened runtime（忽略 DYLD 注入）才完整堵住
        // "同用户进程冒充 App 驱动 root helper"。代价：重构建 App（cdhash 变）需重装助手。
        let clientCDHashHex = try requireCDHashHex(at: clientExecutableURL)

        // 修复 C.1：plist 指向 root-only helper 拷贝（用户改不动），不再直指 bundle。
        let installedHelperPath = installedHelperURL.path
        // 修复 C①：sing-box 也拷到 root-only 位置，trust 指向拷贝（不再指 bundle），
        // 消除 verify→exec 的 TOCTOU。cdhash 仍按 bundle 内 sing-box 算（同字节 → 同 cdhash）。
        let installedSingBoxPath = installedSingBoxURL.path

        // trust.json：JSONEncoder 结构化生成（修复 C 加 singBox 字段；D1 trust.json 部分在此完成）。
        // 别字符串插值——clientPath/singBoxPath 可能含 JSON 元字符。
        // helper 比对的是 bundle 路径（SecCodeCopyPath 对 bundle 返回 .app 目录），
        // 主可执行路径只用来算 cdhash。两者都写进 trust.json。
        let clientBundlePath = Bundle.main.bundleURL
            .standardizedFileURL.resolvingSymlinksInPath().path
        let trustConfig = makeTrustConfig(
            clientExecutablePath: clientPath,
            clientBundlePath: clientBundlePath,
            clientCDHashHex: clientCDHashHex,
            singBoxInstalledPath: installedSingBoxPath,
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

        let command = makeInstallScript(
            installedHelperPath: installedHelperPath,
            bundledHelperPath: bundledHelperPath,
            installedSingBoxPath: installedSingBoxPath,
            singBoxPath: singBoxPath,
            trustBase64: trustBase64,
            plistBase64: plistBase64,
            plistPath: plistPath
        )

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

    /// 修复 C②：算 sing-box cdhash；失败 fail-closed（拒绝安装），不静默写 null。
    /// 静默写 null 等于不钉 cdhash，签名损坏/回归时会静默降级。委托给纯函数
    /// `failClosedCDHash` 便于单测覆盖 fail-closed 行为。
    private static func requireCDHashHex(at url: URL) throws -> String {
        try failClosedCDHash(computeCDHashHex(at: url))
    }

    /// 修复 C②：cdhash 计算 fail-closed 的纯函数判定。便于单测：nil/空 cdhash 抛错，
    /// 非空原样返回。install 经 requireCDHashHex(at:) 调用，最终落到此判定。
    static func failClosedCDHash(_ hex: String?) throws -> String {
        guard let hex, !hex.isEmpty else {
            throw PrivilegedLauncherError.authorizationFailed(
                "无法计算 sing-box cdhash，拒绝安装（签名损坏或 codesign 缺失）"
            )
        }
        return hex
    }

    /// 修复 C①：构造 trustConfig，singBoxExecutablePath 指向 root-only 拷贝（不是 bundle）。
    /// 安装脚本（一条 root shell）。抽成纯函数是为了能单测——这段脚本历史上
    /// 反复出问题（launchctl 装载序列），却因为埋在 install() 里而完全没被测到。
    static func makeInstallScript(
        installedHelperPath: String,
        bundledHelperPath: String,
        installedSingBoxPath: String,
        singBoxPath: String,
        trustBase64: String,
        plistBase64: String,
        plistPath: String
    ) -> String {
        let stateDir = HelperConstants.stateDirectory
        let parentDir = (stateDir as NSString).deletingLastPathComponent
        // 修复 A：目录权限用共享常量，与 helper setupSocket 同步（别一处改了另一处漂移）。
        let dirModeOctal = String(HelperConstants.socketDirectoryMode, radix: 8)  // "711"
        return [
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
                // 修复 C①：sing-box 也拷到 root-only 位置（与 helper 同构）。
                // trust.singBoxExecutablePath 指向此拷贝，verify→exec 都在同一路径上，
                // 但路径在 0711 root 目录内、文件 root:wheel 755，攻击者无法原子替换 → 无 TOCTOU。
                "/bin/rm -f \(shellQuote(installedSingBoxPath))",
                "/bin/cp \(shellQuote(singBoxPath)) \(shellQuote(installedSingBoxPath))",
                "/usr/sbin/chown root:wheel \(shellQuote(installedSingBoxPath))",
                "/bin/chmod 755 \(shellQuote(installedSingBoxPath))",
                // trust.json：base64 解码写入，root 0600（含钉死的 sing-box cdhash，用户不可读改）。
                "/usr/bin/printf '%s' \(shellQuote(trustBase64)) | /usr/bin/base64 -D > \(shellQuote(HelperConstants.trustConfigPath))",
                "/usr/sbin/chown root:wheel \(shellQuote(HelperConstants.trustConfigPath))",
                "/bin/chmod 600 \(shellQuote(HelperConstants.trustConfigPath))",
                // plist：base64 解码写入，root 0644（launchd 需可读）。
                "/usr/bin/printf '%s' \(shellQuote(plistBase64)) | /usr/bin/base64 -D > \(shellQuote(plistPath))",
                "/usr/sbin/chown root:wheel \(shellQuote(plistPath))",
                "/bin/chmod 644 \(shellQuote(plistPath))",
                // socket 由 helper 自己建（chmod 0666），这里不预建。
                //
                // 装载序列必须是"卸干净 → 确认真的没了 → 解除 disable → 再装"。
            // 等待预算 10 秒：helper 退出前要停内核，而停内核最坏要走
            // SIGINT→SIGTERM→SIGKILL 三级（每级 2 秒），5 秒不够、会卡在竞态边缘。
                // 直接 bootout 后立刻 bootstrap 会失败：`bootout` 对 launchd 是**异步**的，
                // 旧 label 还挂在那儿时 bootstrap 报 `Bootstrap failed: 5: Input/output error`；
                // 被 `launchctl disable` 过的 label 同样报这个错。两者都会让安装静默失败，
                // 用户表现为"输了密码却还是需重装，而且开 TUN 要输两次密码"。
                "/bin/launchctl bootout system/\(HelperConstants.daemonLabel) 2>/dev/null || true",
                "n=0; while /bin/launchctl print system/\(HelperConstants.daemonLabel) >/dev/null 2>&1 && [ $n -lt 100 ]; do /bin/sleep 0.1; n=$((n+1)); done",
                "/bin/launchctl enable system/\(HelperConstants.daemonLabel) 2>/dev/null || true",
                // 仍失败就再来一轮完整的卸载→装载，把偶发的竞态兜住；两轮都失败才算真失败。
                "/bin/launchctl bootstrap system \(shellQuote(plistPath)) 2>/dev/null || { "
                + "/bin/launchctl bootout system/\(HelperConstants.daemonLabel) 2>/dev/null || true; "
                + "/bin/sleep 1; "
                + "/bin/launchctl bootstrap system \(shellQuote(plistPath)); }",
                // 装载后确认服务真的在（KeepAlive=true，launchd 会立刻拉起）。
                "/bin/launchctl print system/\(HelperConstants.daemonLabel) >/dev/null"
                ].joined(separator: "; ")
    }

    /// 加固（堵 §5.1）：pinnedCDHashHex 钉客户端 App 主可执行的 cdhash——ad-hoc 下光验
    /// identifier 可被"覆盖主可执行 + 同 identifier 重签"绕过，钉 cdhash 让重签因 hash 变化被拒。
    /// 纯函数便于单测。clientCDHashHex 传 nil 表示不钉（旧行为）。
    /// 版本号写当前 `HelperConstants.trustConfigVersion`，helper 据此识别迁移期旧配置。
    static func makeTrustConfig(
        clientExecutablePath: String,
        clientBundlePath: String,
        clientCDHashHex: String?,
        singBoxInstalledPath: String,
        singBoxCDHashHex: String?
    ) -> HelperTrustConfig {
        HelperTrustConfig(
            clientExecutablePath: clientExecutablePath,
            clientBundlePath: clientBundlePath,
            pinnedCDHashHex: clientCDHashHex,
            singBoxExecutablePath: singBoxInstalledPath,
            singBoxCDHashHex: singBoxCDHashHex,
            version: HelperConstants.trustConfigVersion
        )
    }

    /// 卸载：一条 osascript 提权完成 bootout、删 plist/socket/stateDirectory。
    public static func uninstall(
        authorizer: PrivilegedAuthorizer,
        timeout: TimeInterval = 60
    ) async throws {
        let command = [
            "export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
            // 卸载会删掉 socket 与整个 state 目录：内核不先停就变成 App 再也停不掉的
            // 残留 root 进程（持有 utun/auto_route/被劫持的 DNS）。App 侧已先发 stopTun，
            // 但 helper 已死/不可达时那条走不通，这里按「完整命令行 == root-only sing-box +
            // 固定 argv」兜底停一次（§1.4：只匹配 helper 自己 exec 的那条命令行）。
            "/usr/bin/pkill -f \(shellQuote(installedSingBoxURL.path + " run -c /dev/stdin")) 2>/dev/null || true",
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
