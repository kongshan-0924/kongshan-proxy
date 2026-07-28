import Foundation
import HelperProtocol
import Security
import XCTest
@testable import KongshanCore

/// 真机回归：复刻 helper 的身份提取逻辑，对着**已安装并正在运行的 kongshan**跑一遍，
/// 确认它算出来的路径/ cdhash 与安装器写进 trust.json 的值真能对上。
///
/// 这条测试就是为了钉死那个让免密码助手长期完全失效的 bug：
/// `SecCodeCopyPath` 返回的是 `.app` 目录，而安装器一度钉的是主可执行文件路径，
/// 两者恒不相等 → helper 静默拒绝所有连接 → 界面永远显示"需重装"。
/// 纯只读（只读代码签名信息），不改任何系统状态；App 没装/没跑时自动跳过。
final class HelperClientIdentityLiveTests: XCTestCase {
    func testInstalledAppIsTrustedByHelperIdentityRules() throws {
        // 1) 找到正在跑的 App
        let installedExecutable = "/Applications/kongshan.app/Contents/MacOS/kongshan"
        let pids = runningPIDs(matching: installedExecutable)
        try XCTSkipIf(pids.isEmpty, "kongshan 没在运行，跳过探针")
        let pid = pids[0]
        print("[探针] App PID = \(pid)")

        // 2) 复刻 helper 的 extractClientIdentity（用 PID 代替 audit token，得到的是同一个 SecCode）
        var code: SecCode?
        let attrs: [CFString: Any] = [kSecGuestAttributePid: pid]
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code)
        print("[探针] SecCodeCopyGuestWithAttributes status = \(guestStatus)")
        let guestCode = try XCTUnwrap(code)

        var requirement: SecRequirement?
        let reqString = "identifier \"\(HelperConstants.clientSigningIdentifier)\""
        let reqCreated = SecRequirementCreateWithString(reqString as CFString, [], &requirement) == errSecSuccess
        let checkStatus = SecCodeCheckValidityWithErrors(guestCode, [], requirement, nil)
        print("[探针] requirement 创建 = \(reqCreated)，签名校验 status = \(checkStatus)（0 才算过）")

        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(guestCode, [], &staticCode), errSecSuccess)
        let staticCodeValue = try XCTUnwrap(staticCode)

        var info: CFDictionary?
        XCTAssertEqual(
            SecCodeCopySigningInformation(staticCodeValue, SecCSFlags(rawValue: kSecCSSigningInformation), &info),
            errSecSuccess
        )
        let dict = try XCTUnwrap(info as? [String: Any])
        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let cdhash = (dict[kSecCodeInfoUnique as String] as? Data)?
            .map { String(format: "%02x", $0) }.joined()
        print("[探针] helper 看到的 identifier = \(identifier ?? "nil")")
        print("[探针] helper 看到的 cdhash     = \(cdhash ?? "nil")")

        var pathURL: CFURL?
        XCTAssertEqual(SecCodeCopyPath(staticCodeValue, [], &pathURL), errSecSuccess)
        let seenPath = try XCTUnwrap((pathURL as URL?)?.resolvingSymlinksInPath().path)
        print("[探针] helper 看到的 path       = \(seenPath)")

        // 3) 安装器会写进 trust.json 的值
        print("[探针] 安装器写入的 path        = \(installedExecutable)")
        let installerCDHash = cdHashHex(at: URL(fileURLWithPath: installedExecutable))
        print("[探针] 安装器写入的 cdhash      = \(installerCDHash ?? "nil")")

        // 4) 拿这两组值跑真正的判定函数
        let identity = HelperClientIdentity(
            signatureValid: reqCreated && checkStatus == errSecSuccess,
            signingIdentifier: identifier,
            executablePath: seenPath,
            cdHashHex: cdhash
        )
        // 与修复后的安装器写入内容一致：bundle 路径才是身份校验字段。
        let trust = HelperTrustConfig(
            clientExecutablePath: installedExecutable,
            clientBundlePath: "/Applications/kongshan.app",
            pinnedCDHashHex: installerCDHash,
            singBoxExecutablePath: "/Library/Application Support/kongshan/helper/sing-box",
            singBoxCDHashHex: "irrelevant"
        )
        let trusted = HelperTrustEvaluation.isTrusted(identity: identity, trust: trust)
        XCTAssertTrue(trusted, "修复后必须判为可信")
        print("[探针] ===> isTrusted = \(trusted)")
        print("[探针] bundle 路径一致? \(seenPath == trust.clientBundlePath)")
        print("[探针] cdhash 一致? \(cdhash?.lowercased() == installerCDHash?.lowercased())")
    }

    private func runningPIDs(matching path: String) -> [pid_t] {
        // 返回值是进程个数（不是字节数）；只有第二个入参按字节算。
        let processCount = proc_listallpids(nil, 0)
        guard processCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(processCount) + 64)
        let written = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        var result: [pid_t] = []
        for pid in pids.prefix(Int(written)) where pid > 1 {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { continue }
            let nullIndex = buffer.firstIndex(of: 0) ?? buffer.count
            let text = String(decoding: buffer[0..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if text == path { result.append(pid) }
        }
        return result
    }

    private func cdHashHex(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let cdhash = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return cdhash.map { String(format: "%02x", $0) }.joined()
    }
}

