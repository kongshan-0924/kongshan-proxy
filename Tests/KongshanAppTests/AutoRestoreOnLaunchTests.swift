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
        XCTAssertEqual(state.autoRestoreDecision, .restoreSystemProxy)
    }

    /// 默认必须关闭：升级到新版本不该凭空开始自动改系统代理。
    func testDisabledByDefault() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        XCTAssertFalse(state.autoRestoreOnLaunch)
        state.setLoginItemStatusForTesting(.enabled)
        state.activeModesSnapshotForTesting = [.systemProxy]
        XCTAssertEqual(state.autoRestoreDecision, .skipDisabled)
    }

    /// 手动打开应用不该顺带接管。判据与 KongshanApp 决定是否展示主窗口的信号一致。
    func testDoesNotRestoreWhenNotLaunchedByLoginItem() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state)
        state.setLoginItemStatusForTesting(.notRegistered)
        XCTAssertEqual(state.autoRestoreDecision, .skipNotLoginLaunch)
    }

    /// 上次是关着的（快照为空）就不该恢复。
    func testDoesNotRestoreWithoutSnapshot() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [])
        XCTAssertEqual(state.autoRestoreDecision, .skipNoSnapshot)
    }

    /// **第一阶段不恢复 TUN**：助手需重装时它会回退到 osascript 弹管理员密码框，
    /// 开机瞬间弹框体验极差。含 TUN 时整体跳过，而不是只恢复系统代理那一半——
    /// 部分恢复会让用户处在与关机前不同的网络姿态却毫无察觉。
    func testSkipsEntirelyWhenSnapshotContainsTUN() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(root: root)
        armed(state, modes: [.systemProxy, .tun])
        XCTAssertEqual(state.autoRestoreDecision, .skipTUNSnapshot)
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
        XCTAssertEqual(state.autoRestoreDecision, .skipDisabled)
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
        XCTAssertEqual(state.autoRestoreDecision, .skipNoSnapshot)
    }
}
