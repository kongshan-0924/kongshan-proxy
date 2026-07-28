import XCTest
@testable import KongshanCore
@testable import HelperProtocol

/// 修复 C①：sing-box 拷到 root-only 位置，trust.singBoxExecutablePath 指向拷贝（而非 bundle）。
/// 消除 verify→exec 的 TOCTOU：bundle 内 sing-box 对 admin 组可写，攻击者可在校验后、
/// posix_spawn 前原子替换 → root 执行任意二进制。root-only 拷贝不可写 → 无 TOCTOU。
final class PrivilegedHelperInstallerC1Tests: XCTestCase {
    func testInstalledSingBoxURLIsInRootOnlyStateDirectory() {
        let url = PrivilegedHelperInstaller.installedSingBoxURL
        // 落在 0711 root 拥有的 stateDirectory 内（与 helper 拷贝同目录）。
        XCTAssertEqual(url.deletingLastPathComponent().path, HelperConstants.stateDirectory)
        XCTAssertEqual(url.lastPathComponent, "sing-box")
    }

    func testInstalledSingBoxURLSharesDirectoryWithInstalledHelperURL() {
        // 与 helper 拷贝同目录，享受同一 0711 root 目录保护。
        XCTAssertEqual(
            PrivilegedHelperInstaller.installedSingBoxURL.deletingLastPathComponent().path,
            PrivilegedHelperInstaller.installedHelperURL.deletingLastPathComponent().path
        )
    }

    func testInstalledSingBoxURLDiffersFromBundledSingBoxURL() {
        // 必须不同于 bundle 内 sing-box 路径——bundle 对 admin 组可写，是 TOCTOU 源头。
        XCTAssertNotEqual(
            PrivilegedHelperInstaller.installedSingBoxURL.path,
            PrivilegedHelperInstaller.bundledSingBoxURL.path
        )
    }

    func testMakeTrustConfigPointsToRootOnlyCopyNotBundle() {
        // C① 验收要点：trust 里 singBoxExecutablePath 指向 root-only 拷贝路径，而非 bundle。
        let clientPath = "/Applications/kongshan.app/Contents/MacOS/kongshan"
        let installedPath = PrivilegedHelperInstaller.installedSingBoxURL.path
        let bundlePath = PrivilegedHelperInstaller.bundledSingBoxURL.path
        let trust = PrivilegedHelperInstaller.makeTrustConfig(
            clientExecutablePath: clientPath,
            clientBundlePath: "/Applications/kongshan.app",
            clientCDHashHex: "clientcdhash11",
            singBoxInstalledPath: installedPath,
            singBoxCDHashHex: "aabbccdd"
        )
        XCTAssertEqual(trust.singBoxExecutablePath, installedPath)
        XCTAssertNotEqual(trust.singBoxExecutablePath, bundlePath)
        // client 路径与 cdhash 仍正确写入。
        XCTAssertEqual(trust.clientExecutablePath, clientPath)
        // helper 比对的是 bundle 路径，必须写进去且与主可执行路径不同。
        XCTAssertEqual(trust.clientBundlePath, "/Applications/kongshan.app")
        XCTAssertNotEqual(trust.clientBundlePath, trust.clientExecutablePath)
        XCTAssertEqual(trust.singBoxCDHashHex, "aabbccdd")
        // 加固：pinnedCDHashHex 现钉客户端 App cdhash（堵 §5.1 identifier 伪造）。
        XCTAssertEqual(trust.pinnedCDHashHex, "clientcdhash11")
    }

    func testMakeTrustConfigCDHashPreservedForPinning() {
        // cdhash 仍按 bundle 内 sing-box 算并钉死——拷贝是同字节 → 同 cdhash，
        // 钉死变冗余但保留（多一层防御）。makeTrustConfig 不改 cdhash。
        let trust = PrivilegedHelperInstaller.makeTrustConfig(
            clientExecutablePath: "/x/kongshan",
            clientBundlePath: "/x/kongshan.app",
            clientCDHashHex: nil,
            singBoxInstalledPath: "/y/sing-box",
            singBoxCDHashHex: "deadbeef"
        )
        XCTAssertEqual(trust.singBoxCDHashHex, "deadbeef")
        // clientCDHashHex 传 nil → 不钉（保留旧行为路径可测）。
        XCTAssertNil(trust.pinnedCDHashHex)
    }
}

/// 修复 C②：computeCDHashHex 失败要 fail-closed。
/// 原实现 nil 时静默写 null → isCDHashMatched 对 nil 放行 → 无 pin。
/// 签名损坏/回归时会静默降级。修复后 nil/空 → 拒绝安装。
final class PrivilegedHelperInstallerC2Tests: XCTestCase {
    func testFailClosedCDHashRejectsNil() {
        XCTAssertThrowsError(try PrivilegedHelperInstaller.failClosedCDHash(nil)) { error in
            // 必须是 authorizationFailed（拒绝安装），不能是别的或被吞掉。
            guard case let PrivilegedLauncherError.authorizationFailed(message) = error else {
                return XCTFail("期望 authorizationFailed，实际：\(error)")
            }
            XCTAssertTrue(message.contains("cdhash"))
        }
    }

    func testFailClosedCDHashRejectsEmptyString() {
        // 空字符串也视为未算出 → 拒绝（防 codesign 返回空 data 的边角情况）。
        XCTAssertThrowsError(try PrivilegedHelperInstaller.failClosedCDHash(""))
    }

    func testFailClosedCDHashPassesThroughNonEmpty() throws {
        // 非空 cdhash 原样返回，正常安装路径不受影响。
        let hex = try PrivilegedHelperInstaller.failClosedCDHash("aabbccddeeff")
        XCTAssertEqual(hex, "aabbccddeeff")
    }

    func testFailClosedCDHashPreservesCase() throws {
        // 大小写保留（与 HelperSingBoxTrust.isCDHashMatched 的大小写不敏感比对配套）。
        let hex = try PrivilegedHelperInstaller.failClosedCDHash("AABBCCDD")
        XCTAssertEqual(hex, "AABBCCDD")
    }
}

/// 安装脚本本身的测试。这段 root shell 历史上反复出问题（`Bootstrap failed: 5:
/// Input/output error` 导致助手装不上、开 TUN 要输两次密码），却因为埋在 install()
/// 里从来没被测过。抽成纯函数后在这里钉住。
final class PrivilegedHelperInstallScriptTests: XCTestCase {
    private func makeScript() -> String {
        PrivilegedHelperInstaller.makeInstallScript(
            installedHelperPath: "/Library/Application Support/kongshan/helper/KongshanHelper",
            bundledHelperPath: "/Applications/kongshan.app/Contents/MacOS/KongshanHelper",
            installedSingBoxPath: "/Library/Application Support/kongshan/helper/sing-box",
            singBoxPath: "/Applications/kongshan.app/Contents/Resources/sing-box",
            trustBase64: "eyJhIjoxfQ==",
            plistBase64: "PD94bWwgdmVyc2lvbj0iMS4wIj8+",
            plistPath: "/Library/LaunchDaemons/com.kaysen.kongshan.helper.plist"
        )
    }

    /// 用真的 /bin/sh 做语法校验（-n 只解析不执行）。带引号、`||`、`{ }`、
    /// 算术展开的复合脚本很容易写错，靠肉眼看不出来。
    func testScriptIsSyntacticallyValidShell() async throws {
        let script = makeScript()
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "kongshan-install-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-n", file.path],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0, "安装脚本语法错误：\(result.stderr)")
    }

    /// launchd 装载序列：bootout 是异步的，必须等它真的消失、并解除 disable 后再 bootstrap，
    /// 否则报 `Bootstrap failed: 5: Input/output error`。少任何一环都会让助手装不上。
    func testLoadSequenceWaitsForUnloadEnablesAndVerifies() {
        let script = makeScript()
        let label = HelperConstants.daemonLabel
        let bootoutIndex = try? XCTUnwrap(script.range(of: "launchctl bootout system/\(label)")?.lowerBound)
        XCTAssertNotNil(bootoutIndex, "必须先 bootout 旧实例")

        // 等待卸载完成的轮询
        XCTAssertTrue(
            script.contains("while /bin/launchctl print system/\(label)"),
            "bootout 后必须轮询等待旧实例真正消失"
        )
        // 解除可能存在的 disable
        XCTAssertTrue(
            script.contains("launchctl enable system/\(label)"),
            "被 disable 过的 label 会让 bootstrap 直接 EIO，必须先 enable"
        )
        // 顺序：enable 必须在 bootstrap 之前
        let enableAt = script.range(of: "launchctl enable system/\(label)")!.lowerBound
        let bootstrapAt = script.range(of: "launchctl bootstrap system")!.lowerBound
        XCTAssertLessThan(enableAt, bootstrapAt, "enable 必须排在 bootstrap 之前")
        // 失败重试 + 最终确认
        XCTAssertTrue(script.contains("/bin/sleep 1"), "首次 bootstrap 失败要退避重试一次")
        XCTAssertTrue(
            script.hasSuffix("/bin/launchctl print system/\(label) >/dev/null"),
            "脚本结尾必须确认服务真的装上了，否则会静默成功、用户看到的仍是需重装"
        )
    }

    /// 路径含空格（/Library/Application Support/…）必须被正确引用。
    func testPathsWithSpacesAreQuoted() {
        let script = makeScript()
        XCTAssertTrue(script.contains("'/Library/Application Support/kongshan/helper/KongshanHelper'"))
        XCTAssertTrue(script.contains("'/Applications/kongshan.app/Contents/Resources/sing-box'"))
        XCTAssertFalse(script.contains("Application Support/kongshan/helper/KongshanHelper "),
                       "未加引号的空格路径会被拆成两个参数")
    }
}
