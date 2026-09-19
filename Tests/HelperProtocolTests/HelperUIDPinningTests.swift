import XCTest
@testable import HelperProtocol

/// v4 新增的第四个身份维度：**调用方 uid**。
///
/// 背景（2026-09-17 审计）：签名 / identifier / bundle 路径 / cdhash 回答的都是
/// 「跑的是不是那个 App」，没有一个回答「是谁在跑它」。同机第二个本地账号（哪怕不是管理员）
/// 启动同一份 `/Applications/kongshan.app` 时那四项**全部成立**——socket 是 0666、
/// 目录 0711 可穿越——于是可以无密码 `startTun`，以 root 劫持整机路由与 DNS。
final class HelperUIDPinningTests: XCTestCase {
    private let bundlePath = "/Applications/kongshan.app"
    private let identifier = HelperConstants.clientSigningIdentifier
    private let ownerUID: UInt32 = 501
    private let attackerUID: UInt32 = 1_706_700_995

    private func trust(pinnedUID: UInt32?) -> HelperTrustConfig {
        HelperTrustConfig(
            clientExecutablePath: bundlePath + "/Contents/MacOS/kongshan",
            clientBundlePath: bundlePath,
            pinnedUID: pinnedUID
        )
    }

    private func identity(uid: UInt32?) -> HelperClientIdentity {
        HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: identifier,
            executablePath: bundlePath,
            cdHashHex: nil,
            uid: uid
        )
    }

    func testMatchingUIDIsTrusted() {
        XCTAssertTrue(
            HelperTrustEvaluation.isTrusted(identity: identity(uid: ownerUID), trust: trust(pinnedUID: ownerUID))
        )
    }

    /// 核心回归：另一个本地账号跑**同一个 App**（签名/路径/identifier 全对）必须被拒。
    func testDifferentLocalAccountRunningSameAppIsRejected() {
        XCTAssertFalse(
            HelperTrustEvaluation.isTrusted(identity: identity(uid: attackerUID), trust: trust(pinnedUID: ownerUID)),
            "另一个账号跑同一份 App 时前四项校验全部成立，只有 uid 能区分——这条守着它"
        )
    }

    /// 拒绝优先：钉了 uid 但对端 uid 取不到（audit_token 异常）一律拒，不退回放行。
    func testMissingPeerUIDIsRejectedWhenPinned() {
        XCTAssertFalse(
            HelperTrustEvaluation.isTrusted(identity: identity(uid: nil), trust: trust(pinnedUID: ownerUID))
        )
    }

    /// 旧 schema（v3，无 pinnedUID）必须判为「不当前」→ helper 全拒 → App 提示重装。
    /// 不允许以「兼容旧配置」为由让 uid 校验静默失效。
    func testTrustConfigWithoutPinnedUIDIsNotCurrent() {
        let legacy = HelperTrustConfig(
            clientExecutablePath: bundlePath + "/Contents/MacOS/kongshan",
            clientBundlePath: bundlePath,
            pinnedCDHashHex: "abc123",
            singBoxExecutablePath: "/Library/Application Support/kongshan/helper/sing-box",
            singBoxCDHashHex: "def456",
            pinnedUID: nil,
            version: HelperConstants.trustConfigVersion
        )
        XCTAssertFalse(legacy.isCurrent, "缺 pinnedUID 的配置不能被当成当前 schema")
    }

    func testFullyPopulatedV4ConfigIsCurrent() {
        let current = HelperTrustConfig(
            clientExecutablePath: bundlePath + "/Contents/MacOS/kongshan",
            clientBundlePath: bundlePath,
            pinnedCDHashHex: "abc123",
            singBoxExecutablePath: "/Library/Application Support/kongshan/helper/sing-box",
            singBoxCDHashHex: "def456",
            pinnedUID: ownerUID,
            version: HelperConstants.trustConfigVersion
        )
        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(HelperConstants.trustConfigVersion, 4, "uid 钉死随 v4 引入，改版本号要同步改重装路径的预期")
    }

    /// 旧 trust.json（没有 pinnedUID 字段）必须仍能解码——解码失败会让 helper 连
    /// 「这是旧配置、去重装」都判断不出来，只会表现成神秘的全拒。
    func testLegacyJSONWithoutUIDFieldStillDecodes() throws {
        let json = """
        {"clientExecutablePath":"\(bundlePath)/Contents/MacOS/kongshan",
         "clientBundlePath":"\(bundlePath)","version":3}
        """
        let decoded = try JSONDecoder().decode(HelperTrustConfig.self, from: Data(json.utf8))
        XCTAssertNil(decoded.pinnedUID)
        XCTAssertFalse(decoded.isCurrent)
    }
}
