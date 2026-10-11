import AppKit
import KongshanCore
import SwiftUI
import XCTest
@testable import kongshan

/// 用户 2026-10-10 反馈的三处「界面卡」：点测速整个界面变卡；状态栏点断开后一直显示正在关闭；
/// 开代理后再开 TUN 要卡好久。共同根源见各用例说明。
@MainActor
final class UIResponsivenessTests: XCTestCase {
    private func projectRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeState() -> (AppState, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
        let state = AppState(storage: Storage(rootDirectory: root), automaticallyInitialize: false)
        state.isReady = true
        return (state, root)
    }

    private func node(_ name: String, source: UUID) -> ProxyNode {
        ProxyNode(
            sourceID: source, name: name, protocolType: .shadowsocks,
            server: "\(abs(name.hashValue)).example.com", port: 443, password: "p", method: "aes-128-gcm"
        )
    }

    /// 真机 2026-10-08 开 TUN 后的 CPU 采样：主线程耗在代理页左列给每个策略组算副标题，
    /// 每次都把全部节点重新筛一遍「套餐信息」（每个名字跑一次正则）。
    /// 462 个节点 × 几十个策略组，测速回填一批、状态变一次就整套重算。
    func testGroupOptionsForLargeSubscriptionStayCheapAcrossRepeatedRenders() {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = UUID()
        var nodes = (0..<460).map { node("🇯🇵 东京 \($0) | 1x", source: source) }
        nodes.append(node("剩余流量：120 GB", source: source))
        nodes.append(node("491.89 G | 500.00 G", source: source))
        state.nodes = nodes
        state.activeConfigID = source
        let names = nodes.map(\.name)
        state.discoveredPolicyGroups[source] = (0..<30).map { index in
            PolicyGroup(name: "组\(index)", kind: .selector, members: ["组0"] + names)
        }

        XCTAssertEqual(state.testableNodes.count, 460, "两条套餐信息不算可选节点")
        let firstGroup = state.displayPolicyGroups[1]
        XCTAssertEqual(state.groupOptions(firstGroup).count, 461, "子组引用 + 460 个节点，套餐信息被剔除")

        // 模拟测速期间约 40 次整页重绘：每次每个策略组都要成员与当前选择。
        let began = ContinuousClock.now
        for _ in 0..<40 {
            for group in state.displayPolicyGroups {
                let options = state.groupOptions(group)
                _ = state.selectedMemberName(in: group.name, options: options)
            }
        }
        let elapsed = ContinuousClock.now - began
        // 修前同样的循环要筛 40×30×462×2 次套餐信息（每次一条正则），调试构建几十秒；修后是字典查找。
        XCTAssertLessThan(elapsed, .seconds(3), "40 轮 × 30 组用了 \(elapsed)")
    }

    /// 缓存不能吃掉变化：节点换了、生效配置换了，立刻反映。
    func testNodeCatalogFollowsNodeAndConfigChanges() {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID()
        let second = UUID()
        state.nodes = [node("A1", source: first), node("B1", source: second)]
        state.activeConfigID = first
        XCTAssertEqual(state.testableNodes.map(\.name), ["A1"])

        state.nodes.append(node("A2", source: first))
        XCTAssertEqual(state.testableNodes.map(\.name), ["A1", "A2"])

        state.activeConfigID = second
        XCTAssertEqual(state.testableNodes.map(\.name), ["B1"])
        XCTAssertEqual(state.activeConfigNodes.map(\.name), ["B1"])
    }

    /// 测速时 `delays` 与进度每秒变好几次。代理页整页作用域读了它们，左列几十个策略组就跟着整套重算。
    func testProxyPageScopeDoesNotObserveDelaysOrSpeedTestProgress() throws {
        let source = try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/PolicyGroupsView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "struct PolicyGroupsView: View {"))
        let end = try XCTUnwrap(source.range(of: "private struct PolicyMemberList", range: start.upperBound..<source.endIndex))
        let pageScope = source[start.upperBound..<end.lowerBound]
        for forbidden in ["state.delays", "state.speedTestProgress"] {
            XCTAssertFalse(pageScope.contains(forbidden), "代理页整页作用域不能读 \(forbidden)")
        }
        let dashboard = try String(
            contentsOf: projectRoot().appending(path: "Sources/kongshan/DashboardView.swift"),
            encoding: .utf8
        )
        let dashboardStart = try XCTUnwrap(dashboard.range(of: "struct DashboardView: View {"))
        let dashboardEnd = try XCTUnwrap(dashboard.range(of: "private struct DashboardTrafficGroup"))
        XCTAssertFalse(dashboard[dashboardStart.upperBound..<dashboardEnd.lowerBound].contains("state.delays"))
    }

    /// 主窗口关掉后窗口对象仍留着，SwiftUI 却不管窗口可不可见：关着的窗口里页面照样跟着状态重算。
    /// 关窗前停在代理页时，从状态栏断开代理，主线程要在看不见的地方重算好几轮——状态栏于是像卡住了。
    func testClosedMainWindowStopsObservingAndReopensOnLastPage() {
        let (state, root) = makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        state.lastMainWindowPage = .dashboard
        let content = MainWindowContentHost(state: state)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = content.hostingView
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        pump(0.5)

        let openBefore = DashboardView.bodyEvaluations
        state.status = .starting
        pump(0.2)
        XCTAssertGreaterThan(DashboardView.bodyEvaluations, openBefore, "开着时必须跟着更新，否则下面的断言没有意义")

        window.close()
        content.detach()
        pump(0.3)
        let closedBefore = DashboardView.bodyEvaluations
        for _ in 0..<5 {
            state.status = .stopping
            pump(0.1)
            state.status = .off
            pump(0.1)
        }
        XCTAssertEqual(DashboardView.bodyEvaluations, closedBefore, "关着的窗口不该再重算页面")

        state.lastMainWindowPage = .policyGroups
        content.attachIfNeeded()
        XCTAssertTrue(content.isAttached)
        content.attachIfNeeded()
        XCTAssertTrue(content.isAttached, "重复打开不重建")
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
