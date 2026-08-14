import Foundation
import SwiftUI
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 临时自查用：把界面离屏渲染成 PNG，便于在没有屏幕录制权限时核对视觉效果。
@MainActor
final class RenderSnapshotTests: XCTestCase {
    private var outputDirectory: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["KONGSHAN_SNAPSHOT_DIR"] ?? "/tmp/kongshan-shots")
    }

    func testRenderSnapshots() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KONGSHAN_SNAPSHOT_DIR"] == nil)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let state = makeState()

        render(
            DashboardView().environment(state),
            name: "dashboard",
            size: CGSize(width: 800, height: 700)
        )
        render(
            MainWindowView().environment(state),
            name: "main-window",
            size: CGSize(width: 1000, height: 680)
        )

        render(
            NodesView().environment(state),
            name: "nodes-page",
            size: CGSize(width: 820, height: 640)
        )

        state.routingSettings.policyGroups = [
            PolicyGroup(name: "流媒体", kind: .selector),
            PolicyGroup(name: "AI", kind: .urltest)
        ]
        state.discoveredPolicyGroups[state.snapshotSourceID!] = [
            PolicyGroup(name: "Proxies", kind: .selector),
            PolicyGroup(name: "Netflix", kind: .selector),
            PolicyGroup(name: "YouTube", kind: .selector),
            PolicyGroup(name: "AI", kind: .selector),
            PolicyGroup(name: "Telegram", kind: .selector),
            PolicyGroup(name: "Steam", kind: .selector)
        ]
        render(
            PolicyGroupsView().environment(state),
            name: "policy-groups",
            size: CGSize(width: 820, height: 640)
        )

        render(
            RoutingView().environment(state),
            name: "routing",
            size: CGSize(width: 740, height: 640)
        )

        let noSubscriptionRules = makeState()
        noSubscriptionRules.discoveredRules[noSubscriptionRules.snapshotSourceID!] = []
        render(
            RoutingView().environment(noSubscriptionRules),
            name: "routing-no-subscription-rules",
            size: CGSize(width: 740, height: 640)
        )

        // 设置→隧道 的绕过列表：核对不再有「例如…」常驻标签列，值一行一行左对齐。
        render(
            BypassListsPreview(),
            name: "bypass-lists",
            size: CGSize(width: 520, height: 640)
        )
        render(
            LogsView().environment(state),
            name: "logs",
            size: CGSize(width: 740, height: 420)
        )

        // 对照组：确认 .sidebar 样式的 List 在 cacheDisplay 下是否本来就抓不到内容。
        render(
            List { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                .listStyle(.sidebar),
            name: "control-sidebar-list",
            size: CGSize(width: 200, height: 120)
        )

        let running = makeState()
        running.status = .on

        render(
            DashboardView().environment(running),
            name: "dashboard-dark",
            size: CGSize(width: 740, height: 700),
            dark: true
        )
        render(
            MainWindowView().environment(running),
            name: "main-window-dark",
            size: CGSize(width: 1000, height: 680),
            dark: true
        )

        // 菜单栏左键迷你面板：浅色空闲态与深色运行态各一张。
        render(
            MenuBarPopoverView(openMainWindow: {}).environment(state),
            name: "menubar-popover",
            size: CGSize(width: 328, height: 460)
        )
        render(
            MenuBarPopoverView(openMainWindow: {}).environment(running),
            name: "menubar-popover-dark",
            size: CGSize(width: 328, height: 460),
            dark: true
        )
    }

    private struct BypassListsPreview: View {
        @State private var settings: RoutingSettings = {
            var s = RoutingSettings.defaults
            s.bypassDomains = ["localhost", "*.local", "*.cn"]
            return s
        }()

        var body: some View {
            Form {
                BypassListSection(
                    title: "绕过域名（直连）",
                    placeholder: "例如 *.local 或 example.com",
                    addTitle: "添加域名",
                    deleteHelp: "删除域名",
                    identity: "bypass-domain",
                    values: $settings.bypassDomains
                )
                BypassListSection(
                    title: "绕过 IP / CIDR（直连）",
                    placeholder: "例如 192.168.0.0/16",
                    addTitle: "添加 IP / CIDR",
                    deleteHelp: "删除 CIDR",
                    identity: "bypass-cidr",
                    values: $settings.bypassCIDRs
                )
            }
            .formStyle(.grouped)
        }
    }

    private func makeState() -> AppState {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "kongshan-snapshot-\(UUID().uuidString)")
        let state = AppState(
            storage: Storage(rootDirectory: root),
            automaticallyInitialize: false
        )
        let source = SubscriptionSource(
            name: "cdn.metaglide.org",
            url: URL(string: "https://cdn.metaglide.org/sub")!,
            usage: SubscriptionUsage(
                uploadBytes: 21_474_836_480,
                downloadBytes: 506_732_999_999,
                totalBytes: 536_870_912_000,
                expiresAt: Date(timeIntervalSince1970: 1_817_800_000)
            )
        )
        state.subscriptions = [source]
        state.snapshotSourceID = source.id
        let names = [
            "491.89 G | 500.00 G", "Traffic Reset：10 Days Left", "Expire Date：2027/08/07",
            "🇭🇰 香港 IEPL 01", "🇭🇰 香港 IEPL 02", "🇯🇵 东京 BGP",
            "🇸🇬 新加坡 01", "🇺🇸 洛杉矶 CN2", "自建 Hysteria2"
        ]
        let protocols: [ProxyProtocol] = [
            .anytls, .anytls, .anytls,
            .shadowsocks, .shadowsocks, .trojan, .vmess, .anytls, .hysteria2
        ]
        let nodes = zip(names, protocols).enumerated().map { index, pair in
            ProxyNode(
                sourceID: index < 8 ? source.id : nil,
                name: pair.0,
                protocolType: pair.1,
                server: "example.com",
                port: 443
            )
        }
        state.nodes = nodes
        state.selectedNodeID = nodes[3].id
        state.activeConfigID = source.id
        state.discoveredPolicyGroups[source.id] = [
            PolicyGroup(name: "节点选择", kind: .selector, members: ["🇭🇰 香港 IEPL 01", "🇭🇰 香港 IEPL 02", "🇯🇵 东京 BGP", "🇸🇬 新加坡 01", "🇺🇸 洛杉矶 CN2"]),
            PolicyGroup(name: "流媒体", kind: .selector, members: ["🇭🇰 香港 IEPL 01", "🇸🇬 新加坡 01"]),
            PolicyGroup(name: "自动选择", kind: .urltest, members: [])
        ]
        state.discoveredRules[source.id] = [
            SubscriptionRule(type: .domainSuffix, value: "google.com", target: "节点选择"),
            SubscriptionRule(type: .domainSuffix, value: "netflix.com", target: "流媒体"),
            SubscriptionRule(type: .domainKeyword, value: "ad", target: "REJECT"),
            SubscriptionRule(type: .ipCIDR, value: "8.8.8.8/32", target: "DIRECT")
        ]
        state.routingSettings.customRules = [
            CustomRouteRule(
                order: 0,
                type: .domainSuffix,
                value: "opencode.ai",
                action: .proxy,
                proxyGroup: "节点选择"
            ),
            CustomRouteRule(
                order: 1,
                type: .ipCIDR,
                value: "203.0.113.8/32",
                action: .proxy,
                proxyGroup: "节点选择"
            )
        ]
        state.delays = [
            nodes[3].id: 48,
            nodes[4].id: 132,
            nodes[5].id: 216,
            nodes[6].id: 380,
            nodes[7].id: Int?.none as Int?
        ]
        state.isReady = true
        return state
    }

    /// 用真实 NSWindow + NSHostingView 承载再 cacheDisplay，
    /// 这样 ScrollView 内容和 AppKit 原生控件（开关、分段控件）都能正确出图。
    private func render(_ view: some View, name: String, size: CGSize, dark: Bool = false) {
        // cacheDisplay 只画视图层，窗口背景不会进位图，必须在内容里显式铺一层底色。
        let hosting = NSHostingView(
            rootView: AnyView(view.background(Color(nsColor: .windowBackgroundColor)))
        )
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            XCTFail("渲染 \(name) 失败")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("编码 \(name) 失败")
            return
        }
        let url = outputDirectory.appending(path: "\(name).png")
        try? png.write(to: url)
        print("SNAPSHOT \(url.path)")
    }
}
