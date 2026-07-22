import XCTest
@testable import KongshanCore
@testable import HelperProtocol

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
