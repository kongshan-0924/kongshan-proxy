import XCTest
@testable import HelperProtocol

/// 修复 C.2：sing-box cdhash 钉死判定（HelperSingBoxTrust.isCDHashMatched）。
/// 拒绝优先：未钉放行（向后兼容旧 trust.json）；钉了必须匹配。
final class HelperSingBoxTrustTests: XCTestCase {
    func testNilPinnedAllowsAny() {
        // 未钉 cdhash（旧 trust.json）→ 放行，无论 actual 是什么。
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: "abcdef", pinnedCDHashHex: nil))
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: nil, pinnedCDHashHex: nil))
    }

    func testEmptyPinnedTreatedAsUnpinned() {
        // 空字符串视为未钉（与 nil 同）。
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: nil, pinnedCDHashHex: ""))
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: "deadbeef", pinnedCDHashHex: ""))
    }

    func testPinnedAndMatchedCaseInsensitive() {
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: "abcdef0123456789", pinnedCDHashHex: "ABCDEF0123456789"))
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: "ABCDEF0123456789", pinnedCDHashHex: "abcdef0123456789"))
    }

    func testPinnedButMismatchedRejected() {
        XCTAssertFalse(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: "deadbeef", pinnedCDHashHex: "abcdef0123456789"))
    }

    func testPinnedButActualNilRejected() {
        // 钉了但取不到目标 cdhash → 拒绝（拿不到就没法比，拒绝优先）。
        XCTAssertFalse(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: nil, pinnedCDHashHex: "abcdef0123456789"))
    }

    func testBundleSingBoxReplacedWouldBeRejected() {
        // 修复 C 核心场景：bundle 内 sing-box 被替换（ad-hoc 签名零成本），
        // 新 cdhash != 钉死值 → 拒绝 exec（TUN 失败但不提权）。
        let installed = "aabbccddeeff00112233445566778899"
        let replaced = "99887766554433221100ffeeddccbbaa"
        XCTAssertFalse(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: replaced, pinnedCDHashHex: installed))
        XCTAssertTrue(HelperSingBoxTrust.isCDHashMatched(actualCDHashHex: installed, pinnedCDHashHex: installed))
    }
}

/// 修复 C.3：安装位置校验（HelperInstallLocation.isAllowed）。
/// App bundle 不允许在用户家目录下（家目录可写 = bundle 可被替换 = 提权风险）。
final class HelperInstallLocationTests: XCTestCase {
    private let home = "/Users/kaysen"

    func testApplicationsAllowed() {
        let bundle = URL(fileURLWithPath: "/Applications/kongshan.app")
        XCTAssertTrue(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: home))
    }

    func testHomeDirectoryRejected() {
        let bundle = URL(fileURLWithPath: "/Users/kaysen/Desktop/kongshan.app")
        XCTAssertFalse(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: home))
    }

    func testHomeSubdirectoryRejected() {
        let bundle = URL(fileURLWithPath: "/Users/kaysen/Downloads/apps/kongshan.app")
        XCTAssertFalse(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: home))
    }

    func testBundleEqualsHomeRejected() {
        let bundle = URL(fileURLWithPath: "/Users/kaysen")
        XCTAssertFalse(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: home))
    }

    func testEmptyHomeRejected() {
        // 家目录为空 → 拒绝（无法判定，拒绝优先）。
        let bundle = URL(fileURLWithPath: "/Applications/kongshan.app")
        XCTAssertFalse(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: ""))
    }

    func testSiblingOfHomeAllowed() {
        // /Users/shared 不在 /Users/kaysen 之下 → 允许。
        let bundle = URL(fileURLWithPath: "/Users/Shared/kongshan.app")
        XCTAssertTrue(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: home))
    }

    func testHomePrefixSubstringNotRejected() {
        // /Users/kaysen2 不在 /Users/kaysen/ 之下（前缀匹配带 / 边界）→ 允许。
        let bundle = URL(fileURLWithPath: "/Users/kaysen2/kongshan.app")
        XCTAssertTrue(HelperInstallLocation.isAllowed(bundleURL: bundle, homeDirectory: home))
    }
}

/// 修复 A：socket 权限值回归测试。
/// 目录 0711（others 可穿越、不可列）、socket 0666（others 可连）。
/// 防止回退到旧的 0700/0600（会把 App 普通用户进程挡在门外，免密码通道形同虚设）。
final class HelperSocketPermissionTests: XCTestCase {
    func testDirectoryModeIs0711() {
        XCTAssertEqual(HelperConstants.socketDirectoryMode, 0o711)
        // 不是旧的 0700（App 无搜索权限，连不上）。
        XCTAssertNotEqual(HelperConstants.socketDirectoryMode, 0o700)
        // 非 world-writable（防 socket-squatting）。
        XCTAssertEqual(HelperConstants.socketDirectoryMode & 0o002, 0)
    }

    func testFileModeIs0666() {
        XCTAssertEqual(HelperConstants.socketFileMode, 0o666)
        // 不是旧的 0600（App 普通用户无写权限，connect 得 EACCES）。
        XCTAssertNotEqual(HelperConstants.socketFileMode, 0o600)
    }

    func testDirectoryAllowsTraverseButNotList() {
        // 0711 = owner rwx + others --x（可穿越搜索、不可列目录）。
        let mode = HelperConstants.socketDirectoryMode
        XCTAssertEqual(mode & 0o400, 0o400)  // owner read
        XCTAssertEqual(mode & 0o100, 0o100)  // owner execute
        XCTAssertEqual(mode & 0o001, 0o001)  // others execute（可穿越）
        XCTAssertEqual(mode & 0o004, 0)      // others 不可列目录
        XCTAssertEqual(mode & 0o002, 0)      // others 不可写
    }

    func testFileAllowsConnectForOthers() {
        // 0666 = others rw（可 connect）。
        let mode = HelperConstants.socketFileMode
        XCTAssertEqual(mode & 0o006, 0o006)  // others rw
    }
}
