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
            clientCDHashHex: "clientcdhash11",
            singBoxInstalledPath: installedPath,
            singBoxCDHashHex: "aabbccdd"
        )
        XCTAssertEqual(trust.singBoxExecutablePath, installedPath)
        XCTAssertNotEqual(trust.singBoxExecutablePath, bundlePath)
        // client 路径与 cdhash 仍正确写入。
        XCTAssertEqual(trust.clientExecutablePath, clientPath)
        XCTAssertEqual(trust.singBoxCDHashHex, "aabbccdd")
        // 加固：pinnedCDHashHex 现钉客户端 App cdhash（堵 §5.1 identifier 伪造）。
        XCTAssertEqual(trust.pinnedCDHashHex, "clientcdhash11")
    }

    func testMakeTrustConfigCDHashPreservedForPinning() {
        // cdhash 仍按 bundle 内 sing-box 算并钉死——拷贝是同字节 → 同 cdhash，
        // 钉死变冗余但保留（多一层防御）。makeTrustConfig 不改 cdhash。
        let trust = PrivilegedHelperInstaller.makeTrustConfig(
            clientExecutablePath: "/x/kongshan",
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
