import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 开机自启后自动恢复接管。这个功能会在**无人看屏幕**时改动系统网络设置，
/// 每条约束都必须有回归守住。
@MainActor
final class AutoRestoreOnLaunchTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-autorestore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(root: URL) -> AppState {
        AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            automaticallyInitialize: false
        )
    }

    private func armed(_ state: AppState, modes: [ProxyMode] = [.systemProxy]) {
        state.autoRestoreOnLaunch = true
        state.setLoginItemStatusForTesting(.enabled)
        state.activeModesSnapshotForTesting = modes
    }

    func testRestoresSystemProxyWhenEverythingLinesUp() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state)
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .restore([.systemProxy]))
    }

    /// 默认必须关闭：升级到新版本不该凭空开始自动改系统代理。
    func testDisabledByDefault() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        XCTAssertFalse(state.autoRestoreOnLaunch)
        state.setLoginItemStatusForTesting(.enabled)
        state.activeModesSnapshotForTesting = [.systemProxy]
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .skipDisabled)
    }

    /// 手动打开应用不该顺带接管。判据与 KongshanApp 决定是否展示主窗口的信号一致。
    func testDoesNotRestoreWhenNotLaunchedByLoginItem() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state)
        state.setLoginItemStatusForTesting(.notRegistered)
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .skipNotLoginLaunch)
    }

    /// 上次是关着的（快照为空）就不该恢复。
    func testDoesNotRestoreWithoutSnapshot() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [])
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .skipNoSnapshot)
    }

    /// 助手可用时**按快照原样恢复**，包括 TUN——用户要的是"回到关机前的模式"。
    func testRestoresTUNWhenHelperIsHealthy() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [.systemProxy, .tun])
        XCTAssertEqual(
            state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true),
            .restore([.systemProxy, .tun])
        )
    }

    /// 只有 TUN 的快照也要原样恢复，不能被当成"没有系统代理就不恢复"。
    func testRestoresTUNOnlySnapshot() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [.tun])
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .restore([.tun]))
    }

    /// **助手不可用时整组都不恢复**：TUN 会退到 osascript 弹管理员密码框，
    /// 开机自启时凭空弹框不可接受；只恢复系统代理那一半同样不行——
    /// 用户会处在与关机前不同的网络姿态却毫无察觉。
    func testSkipsEntirelyWhenTUNSnapshotButHelperUnavailable() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [.systemProxy, .tun])
        XCTAssertEqual(
            state.autoRestoreDecision(helperIsHealthy: false, isCanonicalBundle: true),
            .skipTUNNeedsHelper
        )
    }

    /// 快照不含 TUN 时，助手可用与否都不影响。
    func testHelperHealthIsIrrelevantWithoutTUN() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [.systemProxy])
        XCTAssertEqual(
            state.autoRestoreDecision(helperIsHealthy: false, isCanonicalBundle: true),
            .restore([.systemProxy])
        )
    }

    /// 跑的不是 `/Applications` 里那份时，一律不接管。
    ///
    /// 真机 2026-09-06 00:40：开机自启拉起的是构建目录副本，它接管了系统代理与 TUN，
    /// 却因为不是安装免密码助手时的那一份而用不了助手——每次开 TUN 都弹密码。
    func testDoesNotRestoreFromANonInstalledCopy() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [.systemProxy])
        XCTAssertEqual(
            state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: false),
            .skipForeignBundle
        )
    }

    /// `/Applications` 里没装时不判——开发/便携运行是合法场景。
    func testCanonicalCheckPassesWhenNothingIsInstalled() {
        let missing = URL(fileURLWithPath: "/Applications/kongshan-not-installed-\(UUID().uuidString).app")
        XCTAssertTrue(AppState.isCanonicalBundle(
            bundleURL: URL(fileURLWithPath: "/tmp/whatever.app"),
            installedURL: missing,
            verifierBypass: false
        ))
    }

    /// 装了就必须是它；路径不同即判非正装。
    func testCanonicalCheckRejectsADifferentCopyWhenInstalled() {
        XCTAssertFalse(AppState.isCanonicalBundle(
            bundleURL: URL(fileURLWithPath: "/Users/someone/build/kongshan.app"),
            installedURL: URL(fileURLWithPath: "/Applications"),
            verifierBypass: false
        ))
        XCTAssertTrue(AppState.isCanonicalBundle(
            bundleURL: URL(fileURLWithPath: "/Applications"),
            installedURL: URL(fileURLWithPath: "/Applications"),
            verifierBypass: false
        ))
    }

    /// M4 校验跑的就是构建目录副本，必须放行——与单实例保护同一个旁路开关。
    func testVerifierBypassAllowsTheBuildCopy() {
        XCTAssertTrue(AppState.isCanonicalBundle(
            bundleURL: URL(fileURLWithPath: "/Users/someone/build/kongshan.app"),
            installedURL: URL(fileURLWithPath: "/Applications"),
            verifierBypass: true
        ))
    }

    /// 快照只在正常退出时写；写入后要能跨重启读回来。
    func testSnapshotRoundTripsThroughSettings() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        state.autoRestoreOnLaunch = true
        await state.recordActiveModesSnapshotForTesting(exitingWith: [.systemProxy])
        XCTAssertEqual(state.activeModesSnapshotForTesting, [.systemProxy], "退出时应取到实时接管方式")

        let reloaded = makeState(root: root)
        await reloaded.initialize()
        XCTAssertTrue(reloaded.autoRestoreOnLaunch)
        XCTAssertEqual(reloaded.activeModesSnapshotForTesting, [.systemProxy])
    }

    /// 关掉开关要清空快照：否则用户过很久再打开开关，会恢复一个早已过时的状态。
    func testTurningOffClearsSnapshot() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state)
        await state.setAutoRestoreOnLaunch(false)
        XCTAssertTrue(state.activeModesSnapshotForTesting.isEmpty)
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .skipDisabled)
    }

    /// 关着代理正常退出 ⇒ 快照为空 ⇒ 下次开机不接管。语义要闭合。
    func testExitingWithProxyOffClearsSnapshot() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        state.autoRestoreOnLaunch = true
        await state.recordActiveModesSnapshotForTesting(exitingWith: [.systemProxy])
        XCTAssertEqual(state.activeModesSnapshotForTesting, [.systemProxy])

        await state.recordActiveModesSnapshotForTesting(exitingWith: [])
        XCTAssertTrue(state.activeModesSnapshotForTesting.isEmpty)
        state.setLoginItemStatusForTesting(.enabled)
        XCTAssertEqual(state.autoRestoreDecision(helperIsHealthy: true, isCanonicalBundle: true), .skipNoSnapshot)
    }
}
