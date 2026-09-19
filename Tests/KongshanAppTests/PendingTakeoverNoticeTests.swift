import Foundation
import KongshanCore
import XCTest
@testable import kongshan

/// 「有待还原的网络服务」是设计中的等待状态，不是故障：等级必须是 info，
/// 而且**判重要跨启动生效**。真机 2026-09-04：`LAN` 服务从系统里消失后，
/// 20:01 / 20:06 / 20:08 三次启动各刷了一对告警——判重当时只存在内存里，
/// 而那个服务可能再也不会回来，消息页会被永久占位。
@MainActor
final class PendingTakeoverNoticeTests: XCTestCase {
    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "kongshan-pending-notice-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func makeState(root: URL) -> AppState {
        AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false)
    }

    private func notices(_ state: AppState) -> [RuntimeEvent] {
        state.runtimeEvents.filter { $0.title == "系统代理有待还原的网络服务" }
    }

    func testNoticeIsInfoAndNotRepeatedAcrossRelaunches() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = makeState(root: root)
        await first.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "启动")
        XCTAssertEqual(notices(first).count, 1)
        XCTAssertEqual(
            notices(first).first?.level, .info,
            "这是等待状态不是故障，用 warning 会让用户以为要处理"
        )

        // 同一实例内重复上报（换网、停止都会走到）不再记。
        await first.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "换网")
        XCTAssertEqual(notices(first).count, 1)

        // **关键**：换个实例＝重启一次，同一批仍然不许重报。
        let second = makeState(root: root)
        let beforeRelaunch = second.runtimeEvents.count
        await second.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "启动")
        XCTAssertEqual(
            second.runtimeEvents.count, beforeRelaunch,
            "跨启动判重失效就会每次开机刷一条，而缺席的服务可能永远不回来"
        )

        // 这批服务变了要照报——用户需要知道又多缺了一个。
        await second.notePendingTakeover(kind: "系统代理", ["LAN", "Shadowrocket"], trigger: "启动")
        XCTAssertEqual(notices(second).count, 1)
    }

    func testNoticeComesBackAfterThePendingSetClears() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = makeState(root: root)
        await first.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "启动")
        XCTAssertEqual(notices(first).count, 1)

        // 服务回来并复位：记录要清掉，否则它下次再缺席时就永远不报了。
        await first.notePendingTakeover(kind: "系统代理", [], trigger: "停止")

        let second = makeState(root: root)
        await second.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "启动")
        XCTAssertEqual(notices(second).count, 1, "清空后再次缺席必须重新提示")
    }

    /// 两类接管各记各的，不能互相顶掉。
    func testProxyAndDNSNoticesAreTrackedSeparately() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let state = makeState(root: root)
        await state.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "启动")
        await state.notePendingTakeover(kind: "系统 DNS", ["LAN"], trigger: "启动")
        XCTAssertEqual(notices(state).count, 1)
        XCTAssertEqual(state.runtimeEvents.filter { $0.title == "系统 DNS有待还原的网络服务" }.count, 1)

        let relaunched = makeState(root: root)
        let before = relaunched.runtimeEvents.count
        await relaunched.notePendingTakeover(kind: "系统代理", ["LAN"], trigger: "启动")
        await relaunched.notePendingTakeover(kind: "系统 DNS", ["LAN"], trigger: "启动")
        XCTAssertEqual(relaunched.runtimeEvents.count, before, "两类都要跨启动判重")
    }
}
