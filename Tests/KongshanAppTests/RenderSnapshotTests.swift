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
        // 出口与风险信息尽早摆好：仪表盘那张「当前出口 IP」卡片要能验证到风险行。
        state.applyExitAnalysisSnapshotFixture()

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
        // 用户实际窗口接近 1400pt 宽：代理页两列在这个宽度下最容易露出排版问题。
        render(
            PolicyGroupsView().environment(state),
            name: "policy-groups-wide",
            size: CGSize(width: 1400, height: 800)
        )

        let noSubscriptionRules = makeState()
        noSubscriptionRules.discoveredRules[noSubscriptionRules.snapshotSourceID!] = []
        // 规则页 09-17 由 VSplitView 改成「自定义 / 订阅」两个分段，表单不再被分割线限高，
        // 四个分区可以同时展开而不互相挤掉——这里一次全展开，把三个输入框都摆进画面。
        // （用户 09-11 报的是 `TextField("标题", text:)` 在 Form(.grouped) 里把标题当成
        // 左侧常驻标签、可编辑区被挤到右边缘看不见。）
        let expandedKeys = [
            "routing.perApp.expanded", "routing.forcedProxy.expanded",
            "routing.bypass.expanded", "routing.sshProxy.expanded",
        ]
        let previousExpansion = expandedKeys.map { UserDefaults.standard.object(forKey: $0) }
        for key in expandedKeys { UserDefaults.standard.set(true, forKey: key) }
        render(
            CustomRoutingRulesView().environment(state),
            name: "routing-custom-expanded",
            size: CGSize(width: 1000, height: 1100)
        )
        for (key, old) in zip(expandedKeys, previousExpansion) {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // 订阅分段：顶部开关窄栏 + 按目标分组的只读列表。
        render(
            SubscriptionRulesBrowserView().environment(state),
            name: "routing-subscription",
            size: CGSize(width: 740, height: 640)
        )
        // 规则集型订阅（真实机场订阅几乎全是 RULE-SET）：状态栏、分组的规则集条数、MATCH 去向。
        // 故意留一份「未下载」，核对部分就绪时的文案。
        let ruleSetState = makeState()
        let ruleSetSource = ruleSetState.snapshotSourceID!
        ruleSetState.discoveredRules[ruleSetSource] = [
            SubscriptionRule(kind: .ruleSet, value: "local-direct", target: "全球直连"),
            SubscriptionRule(kind: .ruleSet, value: "reject", target: "REJECT"),
            SubscriptionRule(kind: .ruleSet, value: "ai", target: "节点选择"),
            SubscriptionRule(kind: .ruleSet, value: "media", target: "流媒体"),
            SubscriptionRule(kind: .ruleSet, value: "proxy", target: "节点选择"),
            SubscriptionRule(kind: .ruleSet, value: "cn", target: "全球直连"),
            SubscriptionRule(kind: .geoIP, value: "CN", target: "全球直连"),
        ]
        ruleSetState.discoveredRuleProviders[ruleSetSource] = ["local-direct", "reject", "ai", "media", "proxy", "cn"].map {
            SubscriptionRuleProvider(name: $0, url: URL(string: "https://rules.example.com/\($0).yaml")!,
                                     behavior: .classical, format: .yaml, interval: 43_200)
        }
        ruleSetState.discoveredMatchTargets[ruleSetSource] = "漏网之鱼"
        let fetched = Date().addingTimeInterval(-3 * 3_600)
        let counts = ["local-direct": 1_204, "reject": 38_512, "ai": 312, "proxy": 21_447, "cn": 17_288]
        ruleSetState.applyRuleSetSnapshotFixture(counts.reduce(into: [:]) { sets, pair in
            let file = URL(fileURLWithPath: "/tmp/\(pair.key).srs")
            sets[pair.key] = PreparedSubscriptionRuleSet(
                name: pair.key, routeTag: "sub-\(pair.key)", routeFile: file, dnsTag: nil, dnsFile: nil,
                sourceFile: file, entryCount: pair.value, fetchedAt: fetched,
                expiresAt: fetched.addingTimeInterval(43_200)
            )
        }, for: ruleSetSource)
        render(
            SubscriptionRulesBrowserView().environment(ruleSetState),
            name: "routing-subscription-rulesets",
            size: CGSize(width: 740, height: 640)
        )
        render(
            SubscriptionRulesBrowserView(expandsAllGroups: true).environment(ruleSetState),
            name: "routing-subscription-rulesets-expanded",
            size: CGSize(width: 740, height: 640)
        )
        // 配置不带订阅规则时的空态。改分段前它占满下半屏，是「布局别扭」的主因。
        render(
            SubscriptionRulesBrowserView().environment(noSubscriptionRules),
            name: "routing-no-subscription-rules",
            size: CGSize(width: 740, height: 640)
        )

        // 设置→隧道 的绕过列表：核对不再有「例如…」常驻标签列，值一行一行左对齐。
        render(
            BypassListsPreview(),
            name: "bypass-lists",
            size: CGSize(width: 520, height: 640)
        )
        state.lanSharing = LANSharingSettings(enabled: true, port: 7890, allowedCIDRs: ["192.168.1.0/24"])
        state.lanSharingBoundPort = 7890
        // 新增的三个容器页与诊断四段：信息架构重构后它们才是用户实际看到的页面。
        render(
            RecordsPageView().environment(state),
            name: "page-records",
            size: CGSize(width: 900, height: 640)
        )
        render(
            ConnectionsPageView().environment(state),
            name: "page-connections",
            size: CGSize(width: 1000, height: 640)
        )
        render(
            DiagnosticsView().environment(state),
            name: "page-diagnostics",
            size: CGSize(width: 900, height: 700)
        )
        render(
            NetworkSelfCheckView().environment(state),
            name: "diagnostics-selfcheck",
            size: CGSize(width: 900, height: 620)
        )
        render(
            RouteHitTestView().environment(state),
            name: "diagnostics-routetest",
            size: CGSize(width: 900, height: 520)
        )
        render(
            DeepDiagnosticsView().environment(state),
            name: "diagnostics-deep",
            size: CGSize(width: 900, height: 560)
        )
        render(
            SharingView().environment(state),
            name: "sharing",
            size: CGSize(width: 820, height: 720)
        )
        // 端口被占用：不悄悄换端口，而是在地址处说明原因。
        let sharingFailure = makeState()
        sharingFailure.lanSharing = LANSharingSettings(enabled: true, port: 7890, allowedCIDRs: [])
        sharingFailure.lanSharingFailure = "局域网共享没有启动：端口 7890 已被其他程序占用。请在共享页换一个端口后点「应用」"
        render(
            SharingView().environment(sharingFailure),
            name: "sharing-port-in-use",
            size: CGSize(width: 820, height: 720)
        )

        render(
            LogsView().environment(state),
            name: "logs",
            size: CGSize(width: 740, height: 420)
        )

        // 出口分析**空态**：本轮事故的根源就是从没渲染过它——三张 GroupBox 各自缩成一团。
        // 现在是一个 ContentUnavailableView + 「开始检测」，必须有图为证。
        let bare = makeState()
        render(
            ExitAnalysisView().environment(bare),
            name: "exit-analysis-empty",
            size: CGSize(width: 920, height: 640)
        )
        // 出口分析页：出口信息 + 站点可达性自测 + DNS 解析器明细。
        render(
            ExitAnalysisView().environment(state),
            name: "exit-analysis",
            size: CGSize(width: 820, height: 900)
        )

        // 对照组：确认 .sidebar 样式的 List 在 cacheDisplay 下是否本来就抓不到内容。
        render(
            List { Label("Dashboard", systemImage: "gauge.with.dots.needle.67percent") }
                .listStyle(.sidebar),
            name: "control-sidebar-list",
            size: CGSize(width: 200, height: 120)
        )

        let running = makeState()
        // 同上：宽/窄仪表盘要能验证「当前出口 IP」卡片上的风险行。
        running.applyExitAnalysisSnapshotFixture()
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

        // 自适应对照：同一页面窄/宽各渲染一张，核对网格列数与工具条折行是否随宽度变化。
        render(
            DashboardView().environment(running),
            name: "dashboard-narrow",
            size: CGSize(width: 600, height: 700)
        )
        render(
            DashboardView().environment(running),
            name: "dashboard-wide",
            size: CGSize(width: 1240, height: 700)
        )
        // 此前三页从未进过快照：连接、消息、设置。设置页尤其长，塌了没人看得见。
        render(
            ConnectionsView().environment(running),
            name: "connections",
            size: CGSize(width: 1000, height: 640),
            afterLayout: { running.applyConnectionsSnapshotFixture() }
        )
        render(
            ConnectionsView().environment(running),
            name: "connections-narrow",
            size: CGSize(width: 620, height: 560),
            afterLayout: { running.applyConnectionsSnapshotFixture() }
        )
        // 消息已并入「日志」页的分段；单独渲染它的警告分段，容器另有一张。
        render(
            MessagesView(tab: .constant(.warnings)).environment(state),
            name: "messages",
            size: CGSize(width: 820, height: 640)
        )
        // 设置页的「网络」分区：新增的「网络自检与修复」在这里，必须有图为证。
        // 设置页四个分区各一张：重构后每个分区都变了，塌了必须看得见。
        for tab in SettingsTab.allCases {
            render(
                SettingsView(initialTab: tab).environment(state),
                name: "settings-\(tab.rawValue)",
                size: CGSize(width: 900, height: 1000)
            )
        }
        render(
            SettingsView().environment(state),
            name: "settings",
            size: CGSize(width: 820, height: 900)
        )
        render(
            SettingsView().environment(state),
            name: "settings-narrow",
            size: CGSize(width: 620, height: 900)
        )
        render(
            LogsView().environment(state),
            name: "logs-narrow",
            size: CGSize(width: 560, height: 420)
        )
        render(
            PolicyGroupsView().environment(state),
            name: "policy-groups-narrow",
            size: CGSize(width: 600, height: 640)
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
            proxyRelay: SnapshotRelay(),
            automaticallyInitialize: false
        )
        let source = SubscriptionSource(
            name: "sub.example.com",
            url: URL(string: "https://sub.example.com/sub")!,
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
    /// `afterLayout` 在窗口起来之后、抓图之前跑。
    ///
    /// 连接页需要它：`onAppear` 会启动监控循环，而循环第一轮发现没有内核就把列表清空
    /// （`startConnectionsMonitoring`），在 render 之前摆好的 fixture 会被冲掉。
    /// 循环两轮之间睡 1.5 秒，所以在 0.3 秒时补回来，0.8 秒抓图时数据还在。
    private func render(
        _ view: some View,
        name: String,
        size: CGSize,
        dark: Bool = false,
        afterLayout: (@MainActor () -> Void)? = nil
    ) {
        // cacheDisplay 只画视图层，窗口背景不会进位图，必须在内容里显式铺一层底色。
        // 显式定尺，不靠 NSHostingView 自己撑开：`Table`（连接页）会用自身的固有尺寸，
        // 于是无论窗口多大都渲染成 400×141pt——两张不同宽度的连接页快照像素完全一样，
        // 等于什么都没测到。加上 `.frame` 后所有页都按请求的尺寸布局。
        let hosting = NSHostingView(
            rootView: AnyView(
                view
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: Theme.windowBackgroundColor))
            )
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
        if let afterLayout {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated(afterLayout) }
        }
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


/// 渲染快照用的中转层：只回一批固定的局域网客户端，让共享页能画出真实的行。
private final class SnapshotRelay: LocalTCPRelaying, @unchecked Sendable {
    func start(preferredPort: UInt16?) async throws -> UInt16 { preferredPort ?? 36815 }
    func setTarget(port: UInt16?) {}
    func startLANSharing(port: UInt16, policy: LANPeerPolicy) async throws -> UInt16 {
        port
    }
    func stopLANSharing() {}
    func stop() {}

    func lanClients() -> [LANClientStats] {
        let now = Date()
        return [
            LANClientStats(address: "192.168.1.23", activeConnections: 4,
                           upload: 12_400_000, download: 143_000_000,
                           firstSeenAt: now.addingTimeInterval(-3_600), lastActiveAt: now),
            LANClientStats(address: "192.168.1.41", activeConnections: 0,
                           upload: 900_000, download: 3_100_000,
                           firstSeenAt: now.addingTimeInterval(-7_200),
                           lastActiveAt: now.addingTimeInterval(-600))
        ]
    }
}
