import AppKit
import KongshanCore
import SwiftUI
import XCTest
@testable import kongshan

/// 主窗口切页耗时基准：按真实规模（300 节点、单组 300 成员、300 条运行事件）摆好状态，
/// 在 960×640 窗口里逐页切换，记录「切页 → 布局 → 绘制」完成的耗时。
/// 只在设置 KONGSHAN_PERF=1 时跑，输出 `PERF 页名 毫秒`，供不同版本对比（2026-11-09 用户反馈切页变慢）。
@MainActor
final class PageSwitchBenchmarkTests: XCTestCase {
    func testPageSwitchTimings() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KONGSHAN_PERF"] == nil)
        let state = makeLargeState()
        let size = CGSize(width: 960, height: 640)
        let hosting = NSHostingView(rootView: MainWindowView(initialPage: .dashboard).environment(state)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        settle(hosting)

        let env = ProcessInfo.processInfo.environment
        let rounds = Int(env["KONGSHAN_PERF_ROUNDS"] ?? "") ?? 3
        let pages = env["KONGSHAN_PERF_PAGES"].map { $0.split(separator: ",").compactMap { SidebarPage(rawValue: String($0)) } }
            ?? SidebarPage.allCases
        var totals: [SidebarPage: [Double]] = [:]
        var layouts: [SidebarPage: [Double]] = [:]
        for _ in 0..<rounds {
            for page in pages + [.dashboard] {
                let start = Date()
                state.requestedPage = page
                // 先只做「视图更新 + 布局」，再单独计绘制，拆开看开销落在哪一段。
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                hosting.layoutSubtreeIfNeeded()
                let laidOut = Date()
                settle(hosting)
                totals[page, default: []].append(Date().timeIntervalSince(start) * 1000)
                layouts[page, default: []].append(laidOut.timeIntervalSince(start) * 1000)
            }
        }
        for page in pages {
            let samples = totals[page] ?? []
            let median = samples.sorted()[samples.count / 2]
            let layout = (layouts[page] ?? []).sorted()[samples.count / 2]
            print(String(format: "PERF %@ %.1f ms（更新+布局 %.1f）(样本 %@)", page.rawValue, median, layout,
                         samples.map { String(format: "%.0f", $0) }.joined(separator: "/")))
        }
    }

    /// 单页单独承载（不含侧栏、工具栏）：与上面对比可区分开销在页面本身还是主窗口外壳。
    func testIsolatedPageTimings() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KONGSHAN_PERF"] == nil)
        let state = makeLargeState()
        let size = CGSize(width: 772, height: 640)
        for page in SidebarPage.allCases {
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = Date()
                let hosting = NSHostingView(rootView: Self.page(page).environment(state)
                    .frame(width: size.width, height: size.height))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = hosting
                settle(hosting)
                samples.append(Date().timeIntervalSince(start) * 1000)
                window.contentView = nil
            }
            print(String(format: "ISOLATED %@ %.1f ms", page.rawValue, samples.sorted()[1]))
        }
    }

    @ViewBuilder
    private static func page(_ page: SidebarPage) -> some View {
        switch page {
        case .dashboard: DashboardView()
        case .nodes: NodesView()
        case .policyGroups: PolicyGroupsView()
        case .routing: RoutingView()
        case .connections: ConnectionsPageView()
        case .records: RecordsPageView()
        case .diagnostics: DiagnosticsView()
        case .settings: SettingsView()
        }
    }

    /// 让 onChange → 重建页面 → 布局 → 绘制全部走完。
    private func settle(_ hosting: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
    }

    private func makeLargeState() -> AppState {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "kongshan-perf-\(UUID().uuidString)")
        let state = AppState(storage: Storage(rootDirectory: root), proxyRelay: PerfRelay(),
                             automaticallyInitialize: false)
        let source = SubscriptionSource(name: "sub.example.com", url: URL(string: "https://sub.example.com/sub")!)
        state.subscriptions = [source]
        state.snapshotSourceID = source.id
        let regions = ["🇭🇰 香港", "🇯🇵 东京", "🇸🇬 新加坡", "🇺🇸 洛杉矶", "🇹🇼 台北", "🇰🇷 首尔"]
        let protocols: [ProxyProtocol] = [.anytls, .shadowsocks, .trojan, .vmess, .hysteria2]
        let nodes = (0..<300).map { index in
            ProxyNode(sourceID: source.id, name: "\(regions[index % regions.count]) \(index / regions.count + 1)",
                      protocolType: protocols[index % protocols.count], server: "example.com", port: 443)
        }
        state.nodes = nodes
        state.selectedNodeID = nodes[0].id
        state.activeConfigID = source.id
        let names = nodes.map(\.name)
        state.discoveredPolicyGroups[source.id] = [
            PolicyGroup(name: "节点选择", kind: .selector, members: names),
            PolicyGroup(name: "自动选择", kind: .urltest, members: names),
            PolicyGroup(name: "AI 服务", kind: .selector, members: Array(names.prefix(60)))
        ] + (0..<12).map { PolicyGroup(name: "分组 \($0)", kind: .selector, members: ["节点选择"] + names.prefix(20)) }
        state.discoveredRules[source.id] = (0..<2000).map {
            SubscriptionRule(type: .domainSuffix, value: "site\($0).example.com", target: "节点选择")
        }
        var delays: [UUID: Int?] = [:]
        for (index, node) in nodes.enumerated() { delays[node.id] = index % 7 == 0 ? nil : 40 + index }
        state.delays = delays
        for index in 0..<300 {
            state.recordRuntimeEvent(level: index % 3 == 0 ? .warning : .info, title: "事件 \(index)",
                                     detail: "第 \(index) 条运行事件的说明", announce: false)
        }
        // 内核日志满载（内存上限 2000 行），日志页切换的真实负担在这里。
        state.appendLiveLogsForTesting((0..<2000).map { index in
            CoreLogEntry(level: index % 9 == 0 ? .warning : .info,
                         message: "[\(1000 + index) 12ms] outbound/vless[节点选择]: outbound connection to site\(index % 300).example.com:443",
                         receivedAt: Date())
        })
        state.isReady = true
        state.setRunningForTesting(modes: [.systemProxy])
        return state
    }
}

private final class PerfRelay: LocalTCPRelaying, @unchecked Sendable {
    func start(preferredPort: UInt16?) async throws -> UInt16 { preferredPort ?? 36815 }
    func setTarget(port: UInt16?) {}
    func startLANSharing(port: UInt16, policy: LANPeerPolicy) async throws -> UInt16 { port }
    func stopLANSharing() {}
    func stop() {}
    func lanClients() -> [LANClientStats] { [] }
}
