import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarPage? = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                sidebarRow(.dashboard)
                Section("管理") {
                    sidebarRow(.nodes)
                    sidebarRow(.policyGroups)
                    sidebarRow(.routing)
                }
                Section("其他") {
                    sidebarRow(.connections)
                    sidebarRow(.logs)
                    sidebarRow(.messages)
                    sidebarRow(.settings)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 186, ideal: 200, max: 250)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarStatus }
        } detail: {
            // 错误与警告在所有页面统一呈现；此前只有仪表盘显示，
            // 其余页面的失败（导入、应用分流、保存设置…）全是静默的。
            VStack(spacing: 0) {
                GlobalNoticeBar(selection: $selection)
                Group {
                    switch selection ?? .dashboard {
                    case .dashboard:
                        DashboardView()
                    case .nodes:
                        NodesView()
                    case .policyGroups:
                        PolicyGroupsView()
                    case .routing:
                        RoutingView()
                    case .connections:
                        ConnectionsView()
                    case .logs:
                        LogsView()
                    case .messages:
                        MessagesView()
                    case .settings:
                        SettingsView()
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
                .accessibilityLabel(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
            }
        }
        .navigationTitle("kongshan")
    }

    private func sidebarRow(_ page: SidebarPage) -> some View {
        Label(page.title, systemImage: page.symbol)
            .tag(page)
    }

    /// 侧栏底部常驻状态条，任何页面下都能看到当前接管方式与节点。
    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(state.statusTint)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.statusText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(state.selectedNode?.name ?? "未选择节点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

/// 全页面统一的提醒条：只显示最新一条（错误优先于警告），完整列表在「消息」页。
private struct GlobalNoticeBar: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarPage?

    var body: some View {
        if let notice = latestNotice {
            HStack(spacing: 8) {
                Image(systemName: notice.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(notice.tint)
                Text(notice.text)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if notice.count > 1 {
                    Text("共 \(notice.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("查看") { selection = .messages }
                    .controlSize(.small)
                Button(notice.dismissTitle, action: notice.dismiss)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(notice.tint.opacity(0.09))
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private var latestNotice: NoticeData? {
        if let error = state.errorMessage {
            return NoticeData(
                text: error,
                symbol: "exclamationmark.octagon.fill",
                tint: .red,
                dismissTitle: "忽略",
                count: 1,
                dismiss: { state.dismissError() }
            )
        }
        if let warning = state.warnings.last {
            return NoticeData(
                text: warning,
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                dismissTitle: "清除",
                count: state.warnings.count,
                dismiss: { state.clearWarnings() }
            )
        }
        return nil
    }

    private struct NoticeData {
        let text: String
        let symbol: String
        let tint: Color
        let dismissTitle: String
        let count: Int
        let dismiss: () -> Void
    }
}

private enum SidebarPage: String, CaseIterable, Identifiable {
    case dashboard
    case nodes
    case policyGroups
    case routing
    case connections
    case logs
    case messages
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .nodes: "配置"
        case .policyGroups: "代理"
        case .routing: "规则"
        case .connections: "连接"
        case .logs: "内核日志"
        case .messages: "消息"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .nodes: "doc.text"
        case .policyGroups: "arrow.triangle.swap"
        case .routing: "arrow.triangle.branch"
        case .connections: "point.3.filled.connected.trianglepath.dotted"
        case .logs: "doc.text.magnifyingglass"
        case .messages: "bell.badge"
        case .settings: "gearshape"
        }
    }
}

// MARK: - 配置

struct NodesView: View {
    @Environment(AppState.self) private var state
    @State private var subscriptionURL = ""
    @State private var showingManualNode = false
    @State private var pendingImportURL: URL?
    @State private var renamingSource: SubscriptionSource?
    @State private var pendingDelete: AppState.ConfigItem?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "配置", subtitle: configSummary) {
                HStack(spacing: 8) {
                    Button {
                        Task { await state.refreshSubscriptions() }
                    } label: {
                        Label("刷新全部", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.subscriptions.isEmpty || state.isBusy)

                    Button {
                        showingManualNode = true
                    } label: {
                        Label("自建节点", systemImage: "plus")
                    }
                }
            }

            importBar

            Divider()

            List {
                ForEach(state.configItems) { item in
                    configRow(item)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if state.configItems.isEmpty {
                    ContentUnavailableView(
                        "还没有配置",
                        systemImage: "doc.badge.plus",
                        description: Text("粘贴 Clash 订阅链接导入一个配置，或添加自建 Hysteria2 节点。")
                    )
                }
            }
        }
        .pageBackground()
        .navigationTitle("配置")
        .sheet(isPresented: $showingManualNode) {
            ManualNodeSheet().environment(state)
        }
        .sheet(item: $pendingImportURL) { url in
            SubscriptionImportSheet(url: url) { subscriptionURL = "" }
        }
        .sheet(item: $renamingSource) { source in
            SubscriptionRenameSheet(source: source) { name in
                Task { await state.renameSubscription(id: source.id, to: name) }
            }
        }
        .confirmationDialog(
            "删除配置“\(pendingDelete?.name ?? "")”？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { delete(item) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("移除该配置的全部节点、策略与规则；正在运行时会重载配置。")
        }
    }

    // MARK: - 配置行

    @ViewBuilder
    private func configRow(_ item: AppState.ConfigItem) -> some View {
        let isActive = state.activeConfigID == item.id
        Button {
            Task { await state.setActiveConfig(item.id) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

                IconBadge(symbol: item.isLocal ? "wrench.and.screwdriver" : "doc.text", tint: item.isLocal ? .orange : .blue, size: 30)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        if isActive {
                            Text("生效中")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text(rowSubtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let usage = item.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
                        ProgressView(value: min(Double(used) / Double(total), 1))
                            .frame(maxWidth: 260)
                            .tint(Double(used) / Double(total) > 0.85 ? .orange : .accentColor)
                    }
                }
                Spacer(minLength: 8)
                rowMenu(item)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
    }

    private func rowSubtitle(_ item: AppState.ConfigItem) -> String {
        var parts = ["\(item.nodeCount) 个节点"]
        if let usage = item.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
            // used 可能是 0（刚订阅、还没跑流量）；Theme.bytes 对 0 返回空串，
            // 直接插值会渲染成「 / 100 GB」。用带占位符的版本。
            parts.append("\(Theme.bytesOrDash(used)) / \(Theme.bytes(total))")
        }
        if let expires = item.usage?.expiresAt {
            parts.append("\(expires.formatted(date: .abbreviated, time: .omitted)) 到期")
        }
        if let updated = item.lastUpdatedAt {
            parts.append("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func rowMenu(_ item: AppState.ConfigItem) -> some View {
        Menu {
            if !item.isLocal, let source = state.subscriptions.first(where: { $0.id == item.id }) {
                Button("重命名…") { renamingSource = source }
                Button("立即更新") { Task { await state.refreshSubscription(id: source.id) } }
                Toggle("参与定时更新", isOn: Binding(
                    get: { source.autoUpdate },
                    set: { enabled in Task { await state.setSubscriptionAutoUpdate(id: source.id, enabled: enabled) } }
                ))
                Divider()
            }
            Button("删除", role: .destructive) { pendingDelete = item }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .disabled(state.isBusy)
    }

    private func delete(_ item: AppState.ConfigItem) {
        Task {
            if item.isLocal {
                await state.removeLocalConfig()
            } else {
                await state.removeSubscription(id: item.id)
            }
        }
    }

    // MARK: - 导入

    private var importBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("粘贴 Clash YAML 订阅链接", text: $subscriptionURL)
                .textFieldStyle(.plain)
                .onSubmit(beginImport)
            Button("导入") { beginImport() }
                .controlSize(.small)
                .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary.opacity(0.6), lineWidth: 0.5))
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    private var configSummary: String {
        "\(state.configItems.count) 个配置 · 生效：\(state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无")"
    }

    private func beginImport() {
        let value = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let url = URL(string: value), url.scheme != nil else {
            state.errorMessage = "订阅 URL 无效"
            return
        }
        pendingImportURL = url
    }
}


extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// 导入是异步网络操作：sheet 保持打开显示进度，失败在 sheet 内给出原因，
/// 成功才关闭。此前是先关 sheet 再后台导入，失败没有任何可见提示。
private struct SubscriptionImportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onImported: () -> Void

    @State private var name = ""
    @State private var autoUpdate = true
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("导入订阅")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text(url.host ?? "订阅"))
                        .disabled(isImporting)
                    Toggle("参与定时自动更新", isOn: $autoUpdate)
                        .disabled(isImporting)
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let importError {
                            Label(importError, systemImage: "exclamationmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text("正在下载并解析…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入") { beginImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
            }
            .padding(16)
        }
        .frame(width: 440, height: 300)
    }

    private func beginImport() {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        Task {
            await state.importSubscription(url: url, name: name, autoUpdate: autoUpdate)
            isImporting = false
            if let message = state.errorMessage {
                importError = message
                // 错误已经就地显示，不再让全局横幅重复报一次。
                state.dismissError()
            } else {
                onImported()
                dismiss()
            }
        }
    }
}

private struct SubscriptionRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: SubscriptionSource
    let onConfirm: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名订阅")
                .font(.system(size: 13, weight: .semibold))
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onConfirm(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = source.name }
    }
}

// MARK: - 设置

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case tunnel
    case network
    case resources
    case more

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .tunnel: "隧道"
        case .network: "网络"
        case .resources: "资源"
        case .more: "更多"
        }
    }
}

private struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var dnsDraft = DNSSettings.defaults
    @State private var subscriptionUpdateDraft = SubscriptionUpdateSettings.defaults
    @State private var testURLDraft = ""
    @State private var routingDraft = RoutingSettings.defaults
    @State private var tunDraft = TunSettings.defaults
    @State private var tab: SettingsTab = .general
    @State private var backupDocument: BackupDocument?
    @State private var showsBackupExporter = false
    @State private var showsBackupImporter = false
    @State private var isPreparingBackup = false
    @State private var backupNotice: String?
    @State private var diagnosticDocument: TextExportDocument?
    @State private var showsDiagnosticExporter = false
    @State private var isPreparingDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "设置", subtitle: nil) {
                Picker("分区", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 340)
            }

            Form {
                if tab == .tunnel {
                Section("外观") {
                    Picker("菜单栏图标", selection: menuBarIconStyleBinding) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            // 直接把三种图标画出来给用户挑，比只列名字直观得多。
                            Label {
                                Text(style.displayName)
                            } icon: {
                                Image(nsImage: MenuBarIcon.image(style: style, state: .systemProxy))
                            }
                            .tag(style)
                        }
                    }
                    Text(state.menuBarIconStyle.summary + "。菜单栏会把图标染成单色，所以状态靠形状区分：关闭时是线稿、开启后填实、TUN 额外加一个点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("代理模式") {
                    // 与仪表盘 / 托盘同一套模型：两种接管可同时开。
                    // 之前这里是单选 Picker，双开时点一下会静默关掉另一种。
                    Toggle(ProxyMode.systemProxy.displayName, isOn: modeToggleBinding(.systemProxy))
                        .disabled(state.isBusy || !state.isReady)
                    Toggle(ProxyMode.tun.displayName, isOn: modeToggleBinding(.tun))
                        .disabled(state.isBusy || !state.isReady)

                    LabeledContent("当前接管", value: activeModesText)

                    Toggle("严格路由（strict_route）", isOn: strictRouteBinding)
                        .disabled(state.isBusy || !state.isReady)

                    Text("TUN 的启动与停止需要管理员授权。严格路由更彻底，但可能影响局域网、虚拟机或其他 VPN。首次开启 TUN 会弹一次密码安装免密码助手，之后启停零弹窗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("TUN 运行期间系统 DNS 会临时指向 \(state.tunSettings.dnsServerAddress) 以防解析绕过 TUN（macOS 特性），关闭或退出时自动还原。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("内网 DNS 分流") {
                    Toggle("把内网域名交给内网 DNS 解析", isOn: lanDNSEnabledBinding)
                        .disabled(state.isBusy || !state.isReady)

                    LabeledContent("自动探测到的 DNS", value: detectedLANServersText)
                    LabeledContent("自动探测到的域名", value: detectedLANDomainsText)

                    TextField("内网 DNS 服务器（留空＝用自动探测）", text: $tunDraft.lanDNSServer)
                        .disabled(!state.tunSettings.lanDNSEnabled || state.isBusy || !state.isReady)

                    Text("关掉它，内网域名会落到 Fake-IP 拿到一个 240.x 假地址，然后整段被路由进代理出口——表现就是内网设备一直加载。探测在接管系统 DNS 之前进行；网络不下发搜索域时，用下面的列表手填内网域名后缀。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                BypassListSection(
                    title: "内网域名后缀",
                    placeholder: "例如 corp.example.com 或 *.corp.example.com",
                    addTitle: "添加内网域名",
                    deleteHelp: "删除内网域名",
                    identity: "lan-domain",
                    values: $tunDraft.lanDomainSuffixes
                )
                Section {
                    HStack {
                        if tunDraft != state.tunSettings {
                            StatusBadge(text: "有未应用的修改", tint: .orange)
                        }
                        Spacer()
                        // 必须显式应用：改一个字符就重启内核会掐断所有连接。
                        Button("应用内网 DNS 设置") {
                            Task { await state.applyTunSettings(tunDraft) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || tunDraft == state.tunSettings)
                    }
                } footer: {
                    Text("应用会重启内核（掐断当前连接），所以改完一次性应用。开关立即生效，无需按此按钮。")
                }

                // 手动绕过列表挪到这里：可上下滚动，逐条增删域名 / IP。
                BypassListSection(
                    title: "绕过域名（直连）",
                    placeholder: "例如 *.local 或 example.com",
                    addTitle: "添加域名",
                    deleteHelp: "删除域名",
                    identity: "bypass-domain",
                    values: $routingDraft.bypassDomains
                )
                BypassListSection(
                    title: "绕过 IP / CIDR（直连）",
                    placeholder: "例如 192.168.0.0/16",
                    addTitle: "添加 IP / CIDR",
                    deleteHelp: "删除 CIDR",
                    identity: "bypass-cidr",
                    values: $routingDraft.bypassCIDRs
                )
                BypassListSection(
                    title: "跳过 TUN 的网段",
                    placeholder: "例如 10.0.0.0/8",
                    addTitle: "添加网段",
                    deleteHelp: "删除网段",
                    identity: "tun-exclude",
                    values: $routingDraft.tunExcludeCIDRs
                )
                Section {
                    Button("恢复默认绕过列表") {
                        routingDraft.bypassDomains = RoutingSettings.defaults.bypassDomains
                        routingDraft.bypassCIDRs = RoutingSettings.defaults.bypassCIDRs
                        routingDraft.tunExcludeCIDRs = RoutingSettings.defaultTunExcludeCIDRs
                    }
                    HStack {
                        if routingDraft != state.routingSettings {
                            StatusBadge(text: "有未应用的修改", tint: .orange)
                        }
                        Spacer()
                        Button("应用绕过设置") {
                            Task { await state.applyRoutingSettings(routingDraft) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || routingDraft == state.routingSettings)
                    }
                } footer: {
                    Text("绕过域名/IP 会同时生效于分流规则、系统代理 bypass 与 TUN 排除三处。改动统一校验后应用。")
                }

                Section("免密码助手") {
                    LabeledContent("状态", value: helperStatusText)
                    Text("免密码助手让 TUN 启停无需每次输入密码：安装需一次管理员授权，之后开机自动运行。未装时 TUN 仍可用（每次弹密码）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state.helperInstallStatus == .needsReinstall {
                        // 本项目是 ad-hoc 签名，助手只能靠钉死 App 的 cdhash 来认人，
                        // 因此 App 一更新（cdhash 变）助手就必须重装一次。说清楚，别让用户以为坏了。
                        Text("助手在，但不认识当前这个 App —— 通常是 App 更新过（签名变了），或 App 被移动过位置。点「重新安装」授权一次即可，之后继续零弹窗。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    // 安装/卸载都要 bootout helper：TUN 正在跑时做这件事会把 root 内核变成
                    // 孤儿（继续持有 utun/路由/DNS，App 停不掉）。TUN 运行期间一律禁用。
                    if tunActive {
                        Text("TUN 正在运行，安装/卸载助手已暂时禁用——请先关闭 TUN，避免残留无法清理的 root 内核。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        if state.isHelperOperationInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        switch state.helperInstallStatus {
                        case .notInstalled:
                            Button("安装免密码助手") {
                                Task { await state.installHelper() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHelperOperationInProgress || tunActive)
                        case .installed:
                            Button("卸载") {
                                Task { await state.uninstallHelper() }
                            }
                            .disabled(state.isHelperOperationInProgress || tunActive)
                        case .needsReinstall:
                            Button("重新安装") {
                                Task { await state.installHelper() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHelperOperationInProgress || tunActive)
                        }
                    }
                }
                .task { await state.refreshHelperInstallStatus() }

                }
                if tab == .network {
                Section("测速") {
                    Picker("测速方式", selection: speedTestMethodBinding) {
                        ForEach(SpeedTestMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    if state.speedTestMethod == .urlTest {
                        TextField("测试 URL", text: $testURLDraft)
                        HStack {
                            if testURLDraft != state.testURLString {
                                StatusBadge(text: "未保存", tint: .orange)
                            }
                            Spacer()
                            Button("保存地址") { Task { await state.saveTestURL(testURLDraft) } }
                                .disabled(testURLDraft == state.testURLString)
                        }
                    }
                    Text("TCP 握手直连节点服务器，快且稳，不需要开启代理；URL 测速经当前代理请求测试地址，测真实链路但更慢。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DNS 高级设置") {
                    TextField("国内 DoH", text: $dnsDraft.domesticDoH)
                    TextField("远程 DoH", text: $dnsDraft.remoteDoH)
                    Text("geosite-cn 使用国内 DoH 直连解析，其余域名走当前代理的远程 DoH。兼容性优先，默认不启用 fake-ip。系统代理模式只管理进入本地 mixed 代理的解析，不等同于接管 macOS 全局 DNS。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("恢复默认") { dnsDraft = .defaults }
                        Button("放弃修改") { dnsDraft = state.dnsSettings }
                            .disabled(dnsDraft == state.dnsSettings)
                        Spacer()
                        Button("应用 DNS") {
                            Task {
                                await state.applyDNSSettings(dnsDraft)
                                dnsDraft = state.dnsSettings
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || !state.isReady || dnsDraft == state.dnsSettings)
                    }
                }

                }
                if tab == .resources {
                Section("订阅自动更新") {
                    Toggle("启用自动更新", isOn: $subscriptionUpdateDraft.enabled)
                    Stepper(
                        "更新间隔：\(subscriptionUpdateDraft.intervalHours) 小时",
                        value: $subscriptionUpdateDraft.intervalHours,
                        in: 1...168
                    )
                    .disabled(!subscriptionUpdateDraft.enabled)
                    LabeledContent(
                        "下次更新",
                        value: state.nextSubscriptionUpdateAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "未安排"
                    )
                    Text("按最近到期的订阅安排一次更新，完成后重新计算时间，不会持续轮询。失败时保留原节点和缓存，并尝试发送本地通知。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("放弃修改") {
                            subscriptionUpdateDraft = state.subscriptionUpdateSettings
                        }
                        .disabled(subscriptionUpdateDraft == state.subscriptionUpdateSettings)
                        Spacer()
                        Button("应用自动更新设置") {
                            Task {
                                await state.setSubscriptionUpdateSettings(subscriptionUpdateDraft)
                                subscriptionUpdateDraft = state.subscriptionUpdateSettings
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            state.isBusy
                                || !state.isReady
                                || subscriptionUpdateDraft == state.subscriptionUpdateSettings
                        )
                    }
                }

                }
                if tab == .resources {
                Section("GeoIP / 规则集数据库") {
                    Picker("下载源", selection: mirrorBinding) {
                        ForEach(RuleSetMirror.allCases, id: \.self) { mirror in
                            Text(mirror.displayName).tag(mirror)
                        }
                    }
                    Toggle("自动更新", isOn: ruleSetAutoUpdateBinding)
                    LabeledContent("最后更新", value: lastRuleSetUpdateText)
                    HStack {
                        if state.isUpdatingRuleSets {
                            ProgressView().controlSize(.small)
                            Text("正在更新…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("立即更新") {
                            Task { await state.updateRuleSetsNow() }
                        }
                        .disabled(state.isUpdatingRuleSets)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(
                            RuleSetService.sourceURLs(
                                mirror: state.ruleSetSettings.mirror,
                                includeAds: state.routingSettings.blockAds
                            ),
                            id: \.tag
                        ) { source in
                            Text(source.url.absoluteString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    Text("上游是 sing-box 官方开源仓库 SagerNet/sing-geoip 与 sing-geosite，由官方持续维护。下载后用打包内核校验通过才替换缓存；失败或关闭自动更新时沿用最后一次成功的缓存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                }
                if tab == .general {
                Section("开机自启") {
                    Toggle("登录时启动 kongshan", isOn: launchAtLoginBinding)
                        .disabled(
                            !state.isReady
                                || state.loginItemStatus == .requiresApproval
                                || state.loginItemStatus == .notFound
                        )
                    LabeledContent("登录项状态", value: loginItemStatusTitle)
                    if state.loginItemStatus == .requiresApproval {
                        Text("登录项已登记，但需要你在系统设置中批准。应用不会重复发起注册。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开系统登录项设置") {
                            Task { await state.openLoginItemSystemSettings() }
                        }
                    } else if state.loginItemStatus == .notFound {
                        Text("当前运行环境不是可注册的应用包；请从打包后的 kongshan.app 使用此功能。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("刷新状态") {
                            Task { await state.refreshLoginItemStatus() }
                        }
                        .disabled(!state.isReady)
                    }
                }

                Section("关于") {
                    LabeledContent("应用版本", value: Self.appVersion)
                    LabeledContent("应用更新") {
                        Button("查看最新版本") {
                            if let url = URL(string: "https://github.com/kongshan-0924/kongshan-proxy/releases/latest") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    LabeledContent("内核") {
                        HStack(spacing: 8) {
                            Text("sing-box \(state.coreVersion)")
                                .foregroundStyle(.secondary)
                            Button(state.isCheckingKernelUpdate ? "检查中…" : "检查内核更新") {
                                Task { await state.updateKernel() }
                            }
                            .controlSize(.small)
                            .disabled(state.isCheckingKernelUpdate)
                        }
                    }
                }
                }
                if tab == .more {
                Section("备份与恢复") {
                    HStack {
                        Button {
                            prepareBackupExport()
                        } label: {
                            Label("导出配置与设置", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isPreparingBackup)

                        Button {
                            showsBackupImporter = true
                        } label: {
                            Label("导入备份", systemImage: "square.and.arrow.down")
                        }
                        .disabled(state.isOn || state.isBusy)

                        if isPreparingBackup { ProgressView().controlSize(.small) }
                        Spacer()
                        if let backupNotice {
                            StatusBadge(text: backupNotice, tint: .green)
                        }
                    }
                    Text("备份包含订阅链接、订阅配置快照、节点凭据和全部设置，可能含敏感信息；不包含日志、运行时密钥或恢复文件。导入前需先停止代理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("数据与日志") {
                    LabeledContent("故障诊断") {
                        Button {
                            prepareDiagnosticExport()
                        } label: {
                            Label("导出脱敏诊断", systemImage: "stethoscope")
                        }
                        .disabled(isPreparingDiagnostics)
                    }
                    LabeledContent("数据目录") {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([state.supportDirectory])
                        }
                    }
                    LabeledContent("日志目录") {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                state.supportDirectory.appending(path: "logs", directoryHint: .isDirectory)
                            ])
                        }
                    }
                    Text(state.supportDirectory.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("脱敏诊断不包含订阅原文、节点凭据或运行时密钥；日志仍可能包含访问域名和服务器地址，请仅发给可信维护者。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("清理") {
                    LabeledContent("清理缓存", value: state.cacheSizeBytes > 0 ? AppState.formatBytes(state.cacheSizeBytes) : "—")
                    Button("执行清理") {
                        Task { await state.clearRegenerableCaches() }
                    }
                    .disabled(state.isOn || state.isBusy || state.cacheSizeBytes == 0)
                    Text("删除内核日志与规则集缓存，两者都会自动重新生成。设置、订阅缓存和节点不受影响。需先停止内核。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .task { await state.refreshCacheSize() }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .pageBackground()
        .navigationTitle("设置")
        .onAppear {
            dnsDraft = state.dnsSettings
            subscriptionUpdateDraft = state.subscriptionUpdateSettings
            testURLDraft = state.testURLString
            routingDraft = state.routingSettings
            tunDraft = state.tunSettings
        }
        // 绕过设置在别处应用（如恢复默认）后，草稿同步跟上。
        .onChange(of: state.routingSettings) { _, new in routingDraft = new }
        // 开关是立即生效的，草稿要跟上，否则"有未应用的修改"会一直挂着。
        .onChange(of: state.tunSettings) { _, new in tunDraft = new }
        .fileExporter(
            isPresented: $showsBackupExporter,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "kongshan-backup"
        ) { result in
            switch result {
            case .success:
                backupNotice = "已导出"
            case let .failure(error):
                state.errorMessage = "导出备份失败：\(error.localizedDescription)"
            }
            backupDocument = nil
        }
        .fileExporter(
            isPresented: $showsDiagnosticExporter,
            document: diagnosticDocument,
            contentType: .plainText,
            defaultFilename: "kongshan-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                state.errorMessage = "导出诊断失败：\(error.localizedDescription)"
            }
            diagnosticDocument = nil
        }
        .fileImporter(isPresented: $showsBackupImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    Task {
                        await state.importBackup(data)
                        if state.errorMessage == nil {
                            backupNotice = "已恢复"
                            dnsDraft = state.dnsSettings
                            subscriptionUpdateDraft = state.subscriptionUpdateSettings
                            testURLDraft = state.testURLString
                            routingDraft = state.routingSettings
                        }
                    }
                } catch {
                    state.errorMessage = "读取备份失败：\(error.localizedDescription)"
                }
            case let .failure(error):
                state.errorMessage = "选择备份失败：\(error.localizedDescription)"
            }
        }
    }

    private func prepareBackupExport() {
        isPreparingBackup = true
        backupNotice = nil
        Task {
            defer { isPreparingBackup = false }
            do {
                backupDocument = BackupDocument(data: try await state.exportBackup())
                showsBackupExporter = true
            } catch {
                state.errorMessage = "准备备份失败：\(error.localizedDescription)"
            }
        }
    }

    private func prepareDiagnosticExport() {
        isPreparingDiagnostics = true
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                diagnosticDocument = TextExportDocument(text: try await state.exportDiagnostics())
                showsDiagnosticExporter = true
            } catch {
                state.errorMessage = "准备诊断失败：\(error.localizedDescription)"
            }
        }
    }

    /// 从打包进 App 的 Info.plist 读取版本，展示当前运行的是哪个构建。
    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    private var speedTestMethodBinding: Binding<SpeedTestMethod> {
        Binding(
            get: { state.speedTestMethod },
            set: { method in Task { await state.setSpeedTestMethod(method) } }
        )
    }

    private func modeToggleBinding(_ mode: ProxyMode) -> Binding<Bool> {
        Binding(
            get: { state.activeModes.contains(mode) },
            set: { enabled in Task { await state.setMode(mode, enabled: enabled) } }
        )
    }

    private var activeModesText: String {
        let ordered: [ProxyMode] = [.systemProxy, .tun]
        let names = ordered.filter(state.activeModes.contains).map(\.displayName)
        return names.isEmpty ? "未开启" : names.joined(separator: " + ")
    }

    private var helperStatusText: String {
        switch state.helperInstallStatus {
        case .notInstalled: "未安装"
        case .installed: "已安装"
        case .needsReinstall: "需重装"
        }
    }

    /// TUN 是否正在接管。安装/卸载助手会 bootout helper，此时做会留下孤儿 root 内核。
    private var tunActive: Bool {
        state.activeModes.contains(.tun)
    }

    private var detectedLANServersText: String {
        let servers = state.lanResolverSnapshot.servers
        return servers.isEmpty ? "未探测到（接管系统 DNS 前读取）" : servers.joined(separator: "、")
    }

    private var detectedLANDomainsText: String {
        let domains = state.lanResolverSnapshot.searchDomains
        return domains.isEmpty ? "未探测到（可在下方手填）" : domains.joined(separator: "、")
    }

    private var lanDNSEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.tunSettings.lanDNSEnabled },
            set: { enabled in
                var settings = state.tunSettings
                settings.lanDNSEnabled = enabled
                Task { await state.applyTunSettings(settings) }
            }
        )
    }

    private var menuBarIconStyleBinding: Binding<MenuBarIconStyle> {
        Binding(
            get: { state.menuBarIconStyle },
            set: { style in Task { await state.setMenuBarIconStyle(style) } }
        )
    }

    private var strictRouteBinding: Binding<Bool> {
        Binding(
            get: { state.tunSettings.strictRoute },
            set: { enabled in
                var settings = state.tunSettings
                settings.strictRoute = enabled
                Task { await state.applyTunSettings(settings) }
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.loginItemStatus == .enabled },
            set: { enabled in
                Task { await state.setLaunchAtLoginEnabled(enabled) }
            }
        )
    }

    private var mirrorBinding: Binding<RuleSetMirror> {
        Binding(
            get: { state.ruleSetSettings.mirror },
            set: { mirror in
                var settings = state.ruleSetSettings
                settings.mirror = mirror
                Task { await state.setRuleSetSettings(settings) }
            }
        )
    }

    private var ruleSetAutoUpdateBinding: Binding<Bool> {
        Binding(
            get: { state.ruleSetSettings.autoUpdate },
            set: { enabled in
                var settings = state.ruleSetSettings
                settings.autoUpdate = enabled
                Task { await state.setRuleSetSettings(settings) }
            }
        )
    }

    private var lastRuleSetUpdateText: String {
        guard let date = state.ruleSetSettings.lastUpdatedAt else { return "从未更新" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var loginItemStatusTitle: String {
        switch state.loginItemStatus {
        case .notRegistered: "未启用"
        case .enabled: "已启用"
        case .requiresApproval: "等待系统批准"
        case .notFound: "应用包不可用"
        }
    }
}

// MARK: - 手动节点

private struct ManualNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var server = ""
    @State private var port = "443"
    @State private var password = ""
    @State private var sni = ""
    @State private var skipCertificateVerification = false
    @State private var obfsPassword = ""
    @State private var uploadMbps = ""
    @State private var downloadMbps = ""
    @State private var localError: String?
    @State private var mode: Mode = .paste
    @State private var linkText = ""
    @State private var parsed: [ProxyNode] = []

    private enum Mode: String, CaseIterable, Identifiable {
        case paste = "粘贴链接"
        case manual = "手动填写"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加自建节点")
                        .font(.system(size: 13, weight: .semibold))
                    Text("保存后会生成独立的“自建”策略组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 10)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 6)

            if mode == .paste { pasteForm } else { manualForm }

            Divider()
            HStack {
                if mode == .paste, !parsed.isEmpty {
                    Text("将添加 \(parsed.count) 个节点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { mode == .paste ? addParsed() : addNode() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(mode == .paste && parsed.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 470, height: 580)
    }

    // MARK: - 粘贴链接

    private var pasteForm: some View {
        Form {
            Section {
                TextEditor(text: $linkText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 140)
                    .onChange(of: linkText) { _, _ in reparse() }
                HStack {
                    Button {
                        linkText = NSPasteboard.general.string(forType: .string) ?? ""
                        reparse()
                    } label: {
                        Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                    }
                    Spacer()
                    if !linkText.isEmpty {
                        Button("清空") { linkText = ""; parsed = []; localError = nil }
                            .buttonStyle(.link)
                    }
                }
            } header: {
                Text("分享链接")
            } footer: {
                Text("支持 ss / trojan / vmess / vless / hysteria2(hy2) / anytls。可一次粘贴多行，每行一个；解析不了的行会被跳过。")
            }

            if !parsed.isEmpty {
                Section("解析结果") {
                    ForEach(parsed) { node in
                        HStack(spacing: 8) {
                            ProtocolTag(value: node.protocolType)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.name)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text("\(node.server):\(String(node.port))")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if let localError {
                Section {
                    Label(localError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 边打边解析。解析是纯字符串处理、无网络无 IO，几十行链接也是微秒级。
    private func reparse() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            parsed = []
            localError = nil
            return
        }
        parsed = NodeShareLink.parseAll(text)
        guard parsed.isEmpty else {
            localError = nil
            return
        }
        // 一个都没解析出来时才报错。整段按单条再试一次，把真实原因带出来——
        // 「端口无效」「不支持的链接类型」远比一句「没有可用链接」有用。
        do {
            _ = try NodeShareLink.parse(text)
            localError = "没有识别到可用的分享链接"
        } catch {
            localError = error.localizedDescription
        }
    }

    private func addParsed() {
        let nodes = parsed
        guard !nodes.isEmpty else { return }
        Task {
            await state.addManualNodes(nodes)
            if let message = state.errorMessage {
                localError = message
                state.dismissError()
            } else {
                dismiss()
            }
        }
    }

    // MARK: - 手动填写（Hysteria2）

    private var manualForm: some View {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $name)
                    TextField("服务器", text: $server)
                    TextField("端口", text: $port)
                    SecureField("密码", text: $password)
                }
                Section("TLS") {
                    TextField("SNI（可选）", text: $sni)
                    Toggle("跳过证书验证", isOn: $skipCertificateVerification)
                }
                Section("可选参数") {
                    TextField("Obfs 密码（salamander，可选）", text: $obfsPassword)
                    TextField("上行 Mbps（可选）", text: $uploadMbps)
                    TextField("下行 Mbps（可选）", text: $downloadMbps)
                }
                if let localError {
                    Section {
                        Label(localError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
    }

    private func addNode() {
        guard let portValue = Int(port),
              let uploadValue = optionalInt(uploadMbps),
              let downloadValue = optionalInt(downloadMbps) else {
            localError = "端口和带宽必须是整数"
            return
        }
        let form = ManualHysteria2(
            name: name,
            server: server,
            port: portValue,
            password: password,
            sni: sni,
            skipCertificateVerification: skipCertificateVerification,
            obfsPassword: obfsPassword.isEmpty ? nil : obfsPassword,
            uploadMbps: uploadValue,
            downloadMbps: downloadValue
        )
        do {
            _ = try form.makeNode()
        } catch {
            localError = error.localizedDescription
            return
        }
        Task {
            await state.addManual(form)
            if let message = state.errorMessage {
                // 失败原因就地显示，不要表现成「点了没反应」。
                localError = message
                state.dismissError()
            } else {
                dismiss()
            }
        }
    }

    private func optionalInt(_ value: String) -> Int?? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .some(nil) : Int(trimmed).map(Optional.some)
    }
}
