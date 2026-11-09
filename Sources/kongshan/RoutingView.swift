import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 规则页：自定义 / 订阅 两个分段。
///
/// 视觉规范：全 App 统一小窗（Tile）布局。
/// 页面采用 TilePage 容器，顶端放置通用开关与概览细长卡（height: nil），
/// 主体使用 TileGrid(minColumnWidth:) 排布固定高度（TileCard）小窗列表，
/// 每个小窗内部独立滚动，充分利用横向与纵向空间。
struct RoutingView: View {
    enum Tab: String, CaseIterable {
        case custom = "自定义"
        case subscription = "订阅"
    }

    @Environment(AppState.self) private var state
    @State private var tab: Tab = .custom
    @State private var showsRuleSetSheet = false
    /// 订阅规则搜索词：搜索框在页内顶栏（RoutingView），列表在订阅分段里。
    @State private var ruleSearch = ""

    var body: some View {
        // 结构化 switch 而不是 ZStack + opacity：订阅分段网格与规则列表计算量较大，
        // 结构化分支避免在自定义分段时后台持续重算订阅规则。
        Group {
            switch tab {
            case .custom: CustomRoutingRulesView()
            case .subscription: SubscriptionRulesBrowserView(ruleSearch: $ruleSearch)
            }
        }
        .pageTopBar {
                CapsuleSegmentedPicker(options: Tab.allCases, selection: $tab) { $0.rawValue }
                    .fixedSize()
                Spacer(minLength: 8)
                if tab == .subscription {
                    TopBarSearchField(text: $ruleSearch, prompt: "搜索规则或目标策略")
                }
                // 命中测试搬去诊断页了，但产生「这条流量为什么走那里」疑问的现场仍是这一页。
                Button {
                    state.requestPage(.diagnostics)
                } label: {
                    Label("命中测试", systemImage: "scope")
                }
                .help("到诊断页测试某个域名 / IP / 进程会命中哪条规则")
                Button {
                    showsRuleSetSheet = true
                } label: {
                    Label("数据库", systemImage: "cylinder.split.1x2")
                }
                .help("GeoIP 与规则集的下载源、自动更新与立即更新")
        }
        .sheet(isPresented: $showsRuleSetSheet) { RuleSetDatabaseSheet().sheetChrome() }
    }
}

// MARK: - 自定义分段

/// 本机自定义的规则 + 拦截广告开关。
/// 整体采用 TilePage，以小窗网格（TileGrid）承载各类规则，各小窗独立滚动。
struct CustomRoutingRulesView: View {
    @Environment(AppState.self) private var state
    /// `RoutingSettings` 的唯一草稿持有者。守卫测试校验此处声明。
    @State private var routingDraft = RoutingSettings.defaults
    @State private var runningApps: [AppState.RunningApp] = []
    @State private var selectedProcess = ""
    @State private var perAppTarget: PerAppTarget = .proxy
    @State private var forcedProxyKind: ForcedProxyInputKind = .domain
    @State private var forcedProxyInput = ""
    @State private var forcedProxyError: String?
    @State private var bypassDomainInput = ""
    @State private var bypassDomainError: String?
    @State private var bypassCIDRKind: BypassCIDRKind = .bypass
    @State private var bypassCIDRInput = ""
    @State private var bypassCIDRError: String?
    @State private var sshProxyAddress = ""
    @State private var sshProxyPort = 22
    @State private var sshProxyError: String?
    @State private var bypassError: String?
    /// 草稿初值是默认设置，`onAppear` 才换成当前设置；换之前不判「有未应用的修改」，免得底部操作条闪一下。
    @State private var draftLoaded = false

    var body: some View {
        TilePage {
            switchesCard
            TileMasonry(minColumnWidth: 320, maxColumns: 2) {
                perAppCard
                forcedProxyCard
                bypassDomainsCard
                bypassCIDRsCard
            }
            sshProxyCard
        }
        // 有未应用的修改（或上次应用失败）时，操作条固定在页面底部
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if draftLoaded, routingDraft != state.routingSettings || bypassError != nil {
                pendingChangesBar
            }
        }
        .onAppear {
            refreshRunningApps()
            routingDraft = state.routingSettings
            draftLoaded = true
        }
        // 只在草稿未脏时跟随外部变化：脏着就同步会把用户没应用完的编辑冲掉。
        .onChange(of: state.routingSettings) { old, new in
            if routingDraft == old {
                routingDraft = new
            } else {
                // 草稿脏着时只吸收立即生效的开关，否则「应用」会把刚切的拦截广告 / 订阅规则回退。
                if old.blockAds != new.blockAds { routingDraft.blockAds = new.blockAds }
                if old.useSubscriptionRules != new.useSubscriptionRules {
                    routingDraft.useSubscriptionRules = new.useSubscriptionRules
                }
            }
        }
    }

    // MARK: - 顶部细长卡：拦截广告开关

    private var switchesCard: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.controlFill)
                    .frame(width: 32, height: 32)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("拦截广告")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("通用规则，开启后立即生效；规则保存在本机，不随订阅更新")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer(minLength: 12)

            if state.isApplyingRouting {
                ProgressView().controlSize(.mini)
            }
            Toggle("", isOn: blockAdsBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(state.isApplyingRouting)
                .help("过滤常见广告与追踪域名")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - 小窗 1：分应用代理

    private var perAppCard: some View {
        TileCard(
            "分应用代理",
            symbol: "app.badge.checkmark",
            detail: state.processRules.isEmpty ? nil : "\(state.processRules.count) 条",
            height: nil,
            trailing: {
                HStack(spacing: 8) {
                    Button {
                        refreshRunningApps()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .accessibilityLabel("刷新运行中的 App 列表")
                    .help("刷新运行中的 App 列表")

                    Button {
                        chooseInstalledApp()
                    } label: {
                        Image(systemName: "plus.app")
                    }
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .accessibilityLabel("从磁盘选择已安装的 App…")
                    .help("从磁盘选择已安装的 App…")
                }
            },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if runningApps.isEmpty {
                            PillMenuPicker(
                                options: [""],
                                selection: $selectedProcess,
                                title: { _ in "无可选 App" }
                            )
                            .disabled(true)
                        } else {
                            PillMenuPicker(
                                options: runningApps.map(\.processName),
                                selection: $selectedProcess,
                                title: { processName in
                                    if let app = runningApps.first(where: { $0.processName == processName }) {
                                        "\(app.name)（\(app.processName)）"
                                    } else {
                                        processName.isEmpty ? "选择 App" : processName
                                    }
                                },
                                // App 名字常很长：吃掉这一行剩下的宽度，放不下再截断。
                                fills: true
                            )
                        }

                        // 走向最多 150 宽；App 名字长时由 App 那颗胶囊截断，按钮保持原宽。
                        PillMenuPicker(
                            options: perAppTargetOptions,
                            selection: $perAppTarget,
                            title: perAppTargetTitle,
                            maxWidth: 150
                        )
                        .layoutPriority(1)

                        Button("添加 / 更新") { addPerAppRule() }
                            .buttonStyle(.pillProminent)
                            .fixedSize()
                            .layoutPriority(2)
                            .disabled(selectedProcess.isEmpty || state.isApplyingRouting)
                    }

                    RoutingNotice(
                        perAppScopeNote,
                        detail: perAppScopeHelp,
                        style: perAppScopeIsLimited ? Theme.warning : Theme.neutral
                    )
                }
            },
            content: {
                if state.processRules.isEmpty {
                    TileEmptyNote(text: "暂无分应用规则，选择 App 后添加")
                } else {
                    ForEach(state.processRules) { rule in
                        TileRuleRow(
                            symbol: "app",
                            title: rule.value,
                            monospaced: true,
                            showsDivider: rule.id != state.processRules.last?.id,
                            isDisabled: state.isApplyingRouting,
                            deleteHelp: "删除该 App 的分流规则",
                            accessibilityLabel: "删除 \(rule.value)",
                            onDelete: { Task { await state.removeProcessRule(rule.id) } }
                        ) {
                            Text(state.processRuleTargetName(rule))
                                .font(.callout)
                                .foregroundStyle(rule.action == .direct ? Theme.success.text : Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        )
    }

    private var perAppScopeIsLimited: Bool {
        !state.processRules.isEmpty && state.activeModes.contains(.systemProxy)
    }

    private var perAppScopeNote: String {
        if perAppScopeIsLimited {
            return "当前开着系统代理：按 App 分流仅在单开 TUN 时生效"
        }
        return "按进程分流仅对经 TUN 进入内核的流量生效"
    }

    private var perAppScopeHelp: String {
        if perAppScopeIsLimited {
            return "当前开着系统代理：浏览器等遵循系统代理的 App 会先连到空山的本地入口，内核认不出来源，上面的规则管不到它们。要按 App 分流，请只开 TUN。"
        }
        return "只对经 TUN 接管的流量生效。同时开着系统代理时，遵循系统代理的 App 会经空山的本地入口进入内核，不受这些规则约束。"
    }

    // MARK: - 小窗 2：强制代理

    private var forcedProxyCard: some View {
        TileCard(
            "强制代理",
            symbol: "arrow.up.forward.app",
            detail: state.forcedProxyRules.isEmpty ? nil : "\(state.forcedProxyRules.count) 条",
            height: nil,
            // 分段放到标题行右侧：与输入框、按钮挤一行时，三百多点宽的小窗里输入框只剩「example.cc」。
            trailing: {
                CapsuleSegmentedPicker(options: ForcedProxyInputKind.allCases, selection: $forcedProxyKind) { $0.title }
                    .fixedSize()
            },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField(forcedProxyKind.placeholder, text: $forcedProxyInput, prompt: Theme.inputPrompt(forcedProxyKind.placeholder))
                            .labelsHidden()
                            .inputField(isInvalid: forcedProxyError != nil)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity)
                            .onSubmit { addForcedProxyRule() }
                        Button("批量应用") { addForcedProxyRule() }
                            .buttonStyle(.pillProminent)
                            .disabled(
                                forcedProxyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || state.isApplyingRouting
                            )
                    }

                    if let forcedProxyError {
                        RoutingNotice(forcedProxyError, style: Theme.danger)
                    } else {
                        RoutingNotice(
                            "多目标可用空格或逗号分隔；重载内核立即生效。",
                            consequence: "现有连接会断开。",
                            detail: "可用空格、逗号或换行分隔多个目标；代理开着时整批校验通过后重载一次内核立即生效，现有连接会断开。",
                            style: Theme.warning
                        )
                    }
                }
            },
            content: {
                if state.forcedProxyRules.isEmpty {
                    TileEmptyNote(text: "暂无强制代理目标")
                } else {
                    ForEach(state.forcedProxyRules) { rule in
                        TileRuleRow(
                            symbol: rule.type == .ipCIDR ? "number" : "globe",
                            title: rule.value,
                            monospaced: true,
                            showsDivider: rule.id != state.forcedProxyRules.last?.id,
                            isDisabled: state.isApplyingRouting,
                            deleteHelp: "删除强制代理规则",
                            accessibilityLabel: "删除 \(rule.value)"
                        ) {
                            Task { await state.removeForcedProxyRule(rule.id) }
                        }
                    }
                }
            }
        )
        .onChange(of: forcedProxyKind) { _, _ in forcedProxyError = nil }
        .onChange(of: forcedProxyInput) { _, _ in forcedProxyError = nil }
    }

    // MARK: - 小窗 3：直连域名

    private var bypassDomainsCard: some View {
        TileCard(
            "直连域名",
            symbol: "globe",
            detail: routingDraft.bypassDomains.isEmpty ? nil : "\(routingDraft.bypassDomains.count) 条",
            height: nil,
            trailing: {
                Button {
                    routingDraft.bypassDomains = RoutingSettings.defaults.bypassDomains
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.pill)
                .controlSize(.small)
                .accessibilityLabel("恢复默认直连域名")
                .help("恢复默认直连域名")
            },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("*.local 或 example.com", text: $bypassDomainInput, prompt: Theme.inputPrompt("*.local 或 example.com"))
                            .labelsHidden()
                            .inputField(isInvalid: bypassDomainError != nil)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity)
                            .onSubmit(addBypassDomain)
                        Button("添加", action: addBypassDomain)
                            .buttonStyle(.pillProminent)
                            .disabled(bypassDomainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let bypassDomainError {
                        RoutingNotice(bypassDomainError, style: Theme.danger)
                    } else {
                        RoutingNotice(
                            "多域名可用空格或逗号分隔；修改在底部「应用」后生效。",
                            consequence: "重载会断开现有连接。",
                            detail: "改动先存成草稿，点底部的「应用」才生效——重载会断开现有连接。",
                            style: Theme.warning
                        )
                    }
                }
            },
            content: {
                if routingDraft.bypassDomains.isEmpty {
                    TileEmptyNote(text: "暂无直连域名，在上方输入后添加")
                } else {
                    ForEach(Array(routingDraft.bypassDomains.enumerated()), id: \.offset) { index, domain in
                        TileRuleRow(
                            symbol: "globe",
                            title: domain,
                            monospaced: true,
                            showsDivider: index != routingDraft.bypassDomains.count - 1,
                            deleteHelp: "删除 \(domain)",
                            accessibilityLabel: "删除 \(domain)"
                        ) {
                            routingDraft.bypassDomains.remove(at: index)
                        }
                    }
                }
            }
        )
        .onChange(of: bypassDomainInput) { _, _ in bypassDomainError = nil }
        .onChange(of: routingDraft) { _, _ in bypassError = nil }
    }

    // MARK: - 小窗 4：直连 IP 段

    private var bypassCIDRsCard: some View {
        let count = bypassCIDRKind == .bypass ? routingDraft.bypassCIDRs.count : routingDraft.tunExcludeCIDRs.count
        return TileCard(
            "直连 IP 段",
            symbol: "number",
            detail: count > 0 ? "\(count) 条" : nil,
            height: nil,
            trailing: {
                Button {
                    if bypassCIDRKind == .bypass {
                        routingDraft.bypassCIDRs = RoutingSettings.defaults.bypassCIDRs
                    } else {
                        routingDraft.tunExcludeCIDRs = RoutingSettings.defaultTunExcludeCIDRs
                    }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.pill)
                .controlSize(.small)
                .accessibilityLabel("恢复当前列表默认值")
                .help("恢复当前列表默认值")
            },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 6) {
                    CapsuleSegmentedPicker(options: BypassCIDRKind.allCases, selection: $bypassCIDRKind) { $0.title }
                        .fixedSize()

                    HStack(spacing: 8) {
                        TextField(bypassCIDRKind.placeholder, text: $bypassCIDRInput, prompt: Theme.inputPrompt(bypassCIDRKind.placeholder))
                            .labelsHidden()
                            .inputField(isInvalid: bypassCIDRError != nil)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity)
                            .onSubmit(addBypassCIDR)
                        Button("添加", action: addBypassCIDR)
                            .buttonStyle(.pillProminent)
                            .disabled(bypassCIDRInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if let bypassCIDRError {
                        RoutingNotice(bypassCIDRError, style: Theme.danger)
                    } else {
                        RoutingNotice(
                            bypassCIDRKind == .bypass ? "生效于分流规则与系统代理 bypass；底部「应用」生效。" : "完全不进入虚拟网卡；底部「应用」生效。",
                            consequence: "重载会断开现有连接。",
                            detail: "改动先存成草稿，点底部的「应用」才生效——重载会断开现有连接。",
                            style: Theme.warning
                        )
                    }
                }
            },
            content: {
                if bypassCIDRKind == .bypass {
                    if routingDraft.bypassCIDRs.isEmpty {
                        TileEmptyNote(text: "暂无直连 IP 网段，在上方输入后添加")
                    } else {
                        ForEach(Array(routingDraft.bypassCIDRs.enumerated()), id: \.offset) { index, cidr in
                            TileRuleRow(
                                symbol: "number",
                                title: cidr,
                                monospaced: true,
                                showsDivider: index != routingDraft.bypassCIDRs.count - 1,
                                deleteHelp: "删除 \(cidr)",
                                accessibilityLabel: "删除 \(cidr)"
                            ) {
                                routingDraft.bypassCIDRs.remove(at: index)
                            }
                        }
                    }
                } else {
                    if routingDraft.tunExcludeCIDRs.isEmpty {
                        TileEmptyNote(text: "暂无跳过 TUN 的网段，在上方输入后添加")
                    } else {
                        ForEach(Array(routingDraft.tunExcludeCIDRs.enumerated()), id: \.offset) { index, cidr in
                            TileRuleRow(
                                symbol: "number",
                                title: cidr,
                                monospaced: true,
                                showsDivider: index != routingDraft.tunExcludeCIDRs.count - 1,
                                deleteHelp: "删除 \(cidr)",
                                accessibilityLabel: "删除 \(cidr)"
                            ) {
                                routingDraft.tunExcludeCIDRs.remove(at: index)
                            }
                        }
                    }
                }
            }
        )
        .onChange(of: bypassCIDRKind) { _, _ in bypassCIDRError = nil }
        .onChange(of: bypassCIDRInput) { _, _ in bypassCIDRError = nil }
    }

    // MARK: - 小窗 5：SSH 走代理

    private var sshProxyCard: some View {
        TileCard(
            "SSH 走代理",
            symbol: "terminal",
            detail: state.sshProxyTargets.isEmpty ? nil : "\(state.sshProxyTargets.count) 条",
            height: nil,
            trailing: { EmptyView() },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        TextField("IP 地址", text: $sshProxyAddress, prompt: Theme.inputPrompt("IP 地址"))
                            .labelsHidden()
                            .inputField(isInvalid: sshProxyError != nil)
                            .font(.body.monospaced())
                            .onSubmit { addSSHProxyTarget() }

                        TextField("端口", value: $sshProxyPort, format: .number.grouping(.never), prompt: Theme.inputPrompt("端口"))
                            .labelsHidden()
                            .inputField(isInvalid: sshProxyError != nil)
                            .font(.body.monospaced())
                            .frame(width: 72)
                            .onSubmit { addSSHProxyTarget() }

                        Button("添加") { addSSHProxyTarget() }
                            .buttonStyle(.pillProminent)
                            .disabled(
                                sshProxyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || state.isApplyingRouting
                            )
                    }

                    if let sshProxyError {
                        RoutingNotice(sshProxyError, style: Theme.danger)
                    } else {
                        RoutingNotice(
                            "指定 IP 的 SSH 流量通过当前节点；不读取或保存私钥。",
                            detail: "代理开着时添加后立即生效；只修改空山托管的 SSH 配置片段，不会读取或保存 SSH 密码、私钥。",
                            style: Theme.neutral
                        )
                    }
                }
            },
            content: {
                if state.sshProxyTargets.isEmpty {
                    TileEmptyNote(text: "暂无 SSH 代理目标")
                } else {
                    ForEach(state.sshProxyTargets) { target in
                        TileRuleRow(
                            symbol: "terminal",
                            title: "\(target.address):\(target.port)",
                            monospaced: true,
                            showsDivider: target.id != state.sshProxyTargets.last?.id,
                            isDisabled: state.isApplyingRouting,
                            deleteHelp: "删除 SSH 代理目标",
                            accessibilityLabel: "删除 \(target.address):\(target.port)"
                        ) {
                            Task { await state.removeSSHProxyTarget(target) }
                        }
                    }
                }
            }
        )
        .onChange(of: sshProxyAddress) { _, _ in sshProxyError = nil }
        .onChange(of: sshProxyPort) { _, _ in sshProxyError = nil }
    }

    // MARK: - 底部操作栏

    private var pendingChangesBar: some View {
        VStack(spacing: 0) {
            Theme.separator.frame(height: 0.5)
            HStack(spacing: 12) {
                if let bypassError {
                    RoutingNotice(bypassError, style: Theme.danger)
                } else {
                    StatusBadge(text: "有未应用的修改", style: Theme.warning)
                }
                Spacer(minLength: 12)
                if state.isApplyingRouting {
                    ProgressView().controlSize(.small)
                }
                Button("放弃") {
                    routingDraft = state.routingSettings
                    bypassError = nil
                }
                .buttonStyle(.pill)
                .disabled(state.isApplyingRouting)
                Button("应用") { applyBypassDraft() }
                    .buttonStyle(.pillProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(state.isBusy || routingDraft == state.routingSettings)
                    .help("保存并重载内核（⌘S）；现有连接会断开重连")
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.cardFill)
    }


    private func applyBypassDraft() {
        let draft = routingDraft
        bypassError = nil
        Task {
            if await state.applyRoutingSettings(draft) {
                if routingDraft == draft { routingDraft = state.routingSettings }
            } else {
                bypassError = state.errorMessage ?? "未能应用，请检查输入后重试"
            }
        }
    }

    private func addBypassDomain() {
        let entries = bypassDomainInput
            .split { $0 == "," || $0 == "，" || $0.isWhitespace }
            .map(String.init)
        guard !entries.isEmpty else { return }
        var accepted: [String] = []
        for entry in entries {
            guard let value = BypassListSection.normalized(entry, kind: .domain) else {
                bypassDomainError = "「\(entry)」不是有效的域名，例如 example.com 或 *.local"
                return
            }
            if !routingDraft.bypassDomains.contains(value), !accepted.contains(value) {
                accepted.append(value)
            }
        }
        routingDraft.bypassDomains.append(contentsOf: accepted)
        bypassDomainInput = ""
    }

    private func addBypassCIDR() {
        let entries = bypassCIDRInput
            .split { $0 == "," || $0 == "，" || $0.isWhitespace }
            .map(String.init)
        guard !entries.isEmpty else { return }
        var accepted: [String] = []
        for entry in entries {
            guard let value = BypassListSection.normalized(entry, kind: .cidr) else {
                bypassCIDRError = "「\(entry)」不是有效的 IP 或网段，例如 203.0.113.6 或 192.168.0.0/16"
                return
            }
            if bypassCIDRKind == .bypass {
                if !routingDraft.bypassCIDRs.contains(value), !accepted.contains(value) {
                    accepted.append(value)
                }
            } else {
                if !routingDraft.tunExcludeCIDRs.contains(value), !accepted.contains(value) {
                    accepted.append(value)
                }
            }
        }
        if bypassCIDRKind == .bypass {
            routingDraft.bypassCIDRs.append(contentsOf: accepted)
        } else {
            routingDraft.tunExcludeCIDRs.append(contentsOf: accepted)
        }
        bypassCIDRInput = ""
    }

    private var perAppTargetOptions: [PerAppTarget] {
        var options: [PerAppTarget] = [.direct, .proxy]
        for node in state.testableNodes {
            options.append(.node(node.id))
        }
        return options
    }

    private func perAppTargetTitle(_ target: PerAppTarget) -> String {
        switch target {
        case .direct:
            return "直连"
        case .proxy:
            return "默认代理"
        case let .node(id):
            if let node = state.testableNodes.first(where: { $0.id == id }) {
                let flag = NodeNameMetadata.parse(node.name).flag.map { "\($0) " } ?? ""
                return "指定：\(flag)\(node.name)"
            }
            return "指定节点"
        }
    }

    private func refreshRunningApps() {
        runningApps = state.runningApplications
        if !runningApps.contains(where: { $0.processName == selectedProcess }) {
            selectedProcess = runningApps.first?.processName ?? ""
        }
    }

    private func chooseInstalledApp() {
        let panel = NSOpenPanel()
        panel.title = "选择要分流的 App"
        panel.prompt = "选择"
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let processName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !processName.isEmpty else {
            return
        }
        let app = AppState.RunningApp(
            name: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent,
            processName: processName
        )
        if !runningApps.contains(where: { $0.processName == processName }) {
            runningApps.append(app)
            runningApps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        selectedProcess = processName
    }

    private func addPerAppRule() {
        let action: RouteAction
        let target: String?
        switch perAppTarget {
        case .direct:
            action = .direct
            target = nil
        case .proxy:
            action = .proxy
            target = state.primaryGroupName ?? "手动选择"
        case let .node(id):
            guard let node = state.activeConfigNodes.first(where: { $0.id == id }) else { return }
            action = .proxy
            target = ConfigGenerator.outboundTag(for: node)
        }
        Task {
            await state.upsertProcessRule(
                processName: selectedProcess,
                action: action,
                proxyTarget: target
            )
        }
    }

    private func addForcedProxyRule() {
        let input = forcedProxyInput
        let kind = forcedProxyKind
        forcedProxyError = nil
        Task {
            let added = await state.upsertForcedProxyRule(type: kind.ruleType, value: input)
            if added {
                forcedProxyInput = ""
            } else {
                forcedProxyError = state.errorMessage ?? "规则未能添加，请检查输入后重试"
            }
        }
    }

    private func addSSHProxyTarget() {
        let address = sshProxyAddress
        let port = sshProxyPort
        sshProxyError = nil
        Task {
            if await state.upsertSSHProxyTarget(address: address, port: port) {
                sshProxyAddress = ""
            } else {
                sshProxyError = state.errorMessage ?? "SSH 代理目标未能添加"
            }
        }
    }

    private var blockAdsBinding: Binding<Bool> {
        Binding(
            get: { state.routingSettings.blockAds },
            set: { value in
                var settings = state.routingSettings
                settings.blockAds = value
                Task { await state.applyRoutingSettings(settings) }
            }
        )
    }
}

// MARK: - 订阅分段

/// 当前生效配置带出的分流规则，只读。
/// 整体采用 TilePage，每个目标策略作为一个固定高度的小窗，平铺在 TileGrid 中。
struct SubscriptionRulesBrowserView: View {
    @Environment(AppState.self) private var state
    @Binding var ruleSearch: String
    /// 仅供离屏渲染自查保留参数接口（小窗化后各目标小窗内默认自带滚动列表）。
    var expandsAllGroups = false

    init(ruleSearch: Binding<String> = .constant(""), expandsAllGroups: Bool = false) {
        _ruleSearch = ruleSearch
        self.expandsAllGroups = expandsAllGroups
    }

    private var activeName: String {
        state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无"
    }

    var body: some View {
        let subscriptionRules = state.subscriptionRules
        let keyword = ruleSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = keyword.isEmpty
            ? subscriptionRules
            : subscriptionRules.filter { $0.value.lowercased().contains(keyword) || $0.target.lowercased().contains(keyword) }
        let targetGroups = keyword.isEmpty ? groups(of: subscriptionRules) : []
        let ruleSetNames = Self.ruleSetNames(in: subscriptionRules)

        Group {
            if subscriptionRules.isEmpty {
                ContentUnavailableView {
                    Label("当前配置没有自带规则", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("仍会套用内置兜底：私有网段与中国大陆直连、其余走代理。切换到带规则的配置可在此查看。")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TilePage {
                    subscriptionOverviewCard(ruleSetNames: ruleSetNames)

                    if keyword.isEmpty {
                        TileGrid(minColumnWidth: 300) {
                            ForEach(targetGroups) { group in
                                targetGroupCard(group: group)
                            }
                        }

                        if state.routingSettings.useSubscriptionRules, let match = state.activeMatchTarget {
                            Text("以上都没命中的流量（MATCH）→ \(match)")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.top, 2)
                        }
                    } else {
                        searchResultsCard(matched: matched, totalCount: subscriptionRules.count)
                    }
                }
            }
        }
        .background(Theme.canvasBackground)
        .buttonStyle(.pill)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !subscriptionRules.isEmpty {
                PageStatusBar(subtitle(
                    total: subscriptionRules.count, matched: matched.count, groups: targetGroups.count,
                    ruleSets: ruleSetNames.count, keyword: keyword
                ))
            }
        }
    }

    // MARK: - 顶部细长卡：订阅总览与规则集

    private func subscriptionOverviewCard(ruleSetNames: [String]) -> some View {
        TileCard(
            "订阅规则",
            symbol: "arrow.triangle.branch",
            detail: "来自配置「\(activeName)」· 只读",
            height: nil,
            trailing: {
                HStack(spacing: 8) {
                    if state.isApplyingRouting {
                        ProgressView().controlSize(.mini)
                    }
                    Toggle("应用订阅规则", isOn: useSubscriptionRulesBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .help("应用来自当前配置的订阅规则；关掉后套用内置兜底")
                        .disabled(state.isApplyingRouting)
                }
            },
            content: {
                VStack(alignment: .leading, spacing: 6) {
                    if !ruleSetNames.isEmpty {
                        ruleSetStatusRow(names: ruleSetNames)
                    } else {
                        Text("关掉后仍套用内置兜底（私有网段与中国大陆直连，其余走代理）。")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                .help("关掉后仍套用内置兜底（私有网段与中国大陆直连，其余走代理）。")
            }
        )
    }

    private func ruleSetStatusRow(names: [String]) -> some View {
        let sets = state.activeSubscriptionRuleSets
        let ready = names.filter { sets[$0] != nil }
        let entries = ready.reduce(0) { $0 + (sets[$1]?.entryCount ?? 0) }
        let oldest = ready.compactMap { sets[$0]?.fetchedAt }.min()
        return HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text(ready.count == names.count
                 ? "规则集 \(names.count) 个 · 共 \(entries.formatted()) 条"
                 : "规则集已下载 \(ready.count) / \(names.count) 个 · 共 \(entries.formatted()) 条")
                .font(.caption)
            if let oldest {
                Text("最早更新于 \(oldest.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            if state.isDownloadingActiveRuleSets {
                ProgressView().controlSize(.mini)
                Text("正在下载…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button("立即更新") {
                    Task { await state.updateSubscriptionRuleSetsNow() }
                }
                .buttonStyle(.pill)
                .controlSize(.small)
                .help("重新下载当前配置的全部规则集；下载失败的沿用已有缓存")
            }
        }
    }

    // MARK: - 目标策略小窗

    private func targetGroupCard(group: RuleTargetGroup) -> some View {
        let parts = IconTile.split(group.target)
        let icon = targetIcon(for: group.target)
        let tint = targetTint(group.target)

        return TileCard(
            parts.title,
            symbol: parts.emoji == nil ? icon.symbol : nil,
            emoji: parts.emoji,
            detail: "\(group.entryCount.formatted()) 条",
            height: 260,
            trailing: {
                if let composition = group.composition() {
                    Text(composition)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            },
            content: {
                if group.rules.isEmpty {
                    TileEmptyNote(text: "暂无规则")
                } else {
                    ForEach(Array(group.rules.prefix(300).enumerated()), id: \.element.id) { index, rule in
                        RuleRow(
                            rule: rule,
                            tint: tint,
                            showsTarget: false,
                            showsDivider: index < min(group.rules.count, 300) - 1
                        )
                    }
                    if group.rules.count > 300 {
                        Text("还有 \(group.rules.count - 300) 条未显示，用上方搜索定位")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 4)
                    }
                }
            }
        )
    }

    // MARK: - 搜索结果小窗

    private func searchResultsCard(matched: [SubscriptionRule], totalCount: Int) -> some View {
        TileCard(
            "匹配的规则",
            symbol: "magnifyingglass",
            detail: "\(matched.count) / \(totalCount) 条",
            height: 420,
            content: {
                if matched.isEmpty {
                    TileEmptyNote(text: "没有找到匹配「\(ruleSearch)」的规则")
                } else {
                    ForEach(Array(matched.prefix(300).enumerated()), id: \.element.id) { index, rule in
                        RuleRow(
                            rule: rule,
                            tint: targetTint(rule.target),
                            showsTarget: true,
                            showsDivider: index < min(matched.count, 300) - 1
                        )
                    }
                    if matched.count > 300 {
                        Text("仅显示前 300 条，共 \(matched.count) 条匹配——把关键词写得更具体些")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 6)
                    }
                }
            }
        )
    }

    private func subtitle(total: Int, matched: Int, groups: Int, ruleSets: Int, keyword: String) -> String {
        guard total > 0 else { return "当前配置未提供订阅规则" }
        if keyword.isEmpty {
            let sets = ruleSets > 0 ? " · 含 \(ruleSets) 个规则集" : ""
            return "配置「\(activeName)」· \(total) 条规则\(sets) · \(groups) 个目标"
        }
        return "匹配 \(matched) / \(total) 条"
    }

    private static func ruleSetNames(in rules: [SubscriptionRule]) -> [String] {
        var seen = Set<String>()
        return rules.filter { $0.kind == .ruleSet && seen.insert($0.value).inserted }.map(\.value)
    }

    private func groups(of rules: [SubscriptionRule]) -> [RuleTargetGroup] {
        let sets = state.activeSubscriptionRuleSets
        var order: [String] = []
        var buckets: [String: [SubscriptionRule]] = [:]
        for rule in rules {
            if buckets[rule.target] == nil { order.append(rule.target) }
            buckets[rule.target, default: []].append(rule)
        }
        return order
            .map { RuleTargetGroup(target: $0, rules: buckets[$0] ?? [], ruleSets: sets) }
            .sorted { $0.entryCount > $1.entryCount }
    }

    private func targetIcon(for target: String) -> (symbol: String, color: Color) {
        switch target.uppercased() {
        case "DIRECT":
            return ("arrow.right.circle", Theme.success.icon)
        case "REJECT", "REJECT-DROP":
            return ("nosign", Theme.danger.icon)
        default:
            return ("arrow.triangle.branch", Theme.textSecondary)
        }
    }

    private func targetTint(_ target: String) -> Color {
        switch target.uppercased() {
        case "DIRECT": Theme.success.text
        case "REJECT", "REJECT-DROP": Theme.danger.text
        default: Theme.textSecondary
        }
    }

    private var useSubscriptionRulesBinding: Binding<Bool> {
        Binding(
            get: { state.routingSettings.useSubscriptionRules },
            set: { value in
                var settings = state.routingSettings
                settings.useSubscriptionRules = value
                Task { await state.applyRoutingSettings(settings) }
            }
        )
    }
}

// MARK: - 模型与辅助组件

/// 固定输入区显示两行摘要；完整原因在局部弹层阅读，不挤占规则列表。
private struct RoutingNotice: View {
    let text: String
    var consequence: String?
    var detail: String?
    let style: Theme.SemanticColors
    @State private var showsDetail = false

    init(_ text: String, consequence: String? = nil, detail: String? = nil, style: Theme.SemanticColors) {
        self.text = text
        self.consequence = consequence
        self.detail = detail
        self.style = style
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(style.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(consequence == nil ? style.text : Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if let consequence {
                    Text(consequence)
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button { showsDetail.toggle() } label: {
                Image(systemName: "ellipsis")
            }
            .buttonStyle(.pill)
            .controlSize(.small)
            .accessibilityLabel("查看完整说明")
            .popover(isPresented: $showsDetail) {
                ScrollView {
                    Text(detail ?? text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(width: 320, height: 180)
                .background(Theme.cardFill)
            }
        }
        .font(.caption)
    }
}

private enum PerAppTarget: Hashable {
    case direct
    case proxy
    case node(UUID)
}

private enum ForcedProxyInputKind: String, CaseIterable, Identifiable {
    case domain
    case ip

    var id: Self { self }
    var title: String { self == .domain ? "域名" : "IP / CIDR" }
    var placeholder: String { self == .domain ? "example.com" : "203.0.113.8 或 203.0.113.0/24" }
    var ruleType: CustomRuleType { self == .domain ? .domainSuffix : .ipCIDR }
}

private enum BypassCIDRKind: String, CaseIterable, Identifiable {
    case bypass
    case tunExclude

    var id: Self { self }
    var title: String {
        switch self {
        case .bypass: return "直连 IP / CIDR"
        case .tunExclude: return "跳过 TUN"
        }
    }
    var placeholder: String {
        switch self {
        case .bypass: return "203.0.113.6 或 192.168.0.0/16"
        case .tunExclude: return "10.0.0.0/8"
        }
    }
}

/// 一张绕过列表：输入框 + 统一条目行。
/// 供设置页的内网域名后缀以及 RenderSnapshotTests 预览使用。
struct BypassListSection: View {
    enum Kind {
        case domain
        case cidr
    }

    let title: String
    let placeholder: String
    let kind: Kind
    @Binding var values: [String]
    @State private var input = ""
    @State private var inputError: String?

    var body: some View {
        CardSection {
            HStack(spacing: 8) {
                TextField(placeholder, text: $input, prompt: Theme.inputPrompt(placeholder))
                    .labelsHidden()
                    .inputField(isInvalid: inputError != nil)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button("添加", action: add)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let inputError {
                RoutingNotice(inputError, style: Theme.danger)
            }
            if values.isEmpty {
                Text("暂无，在上面填写后添加")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    CustomRuleEntryRow(
                        symbol: kind == .domain ? "globe" : "number",
                        value: value,
                        help: "删除",
                        accessibilityLabel: "删除 \(value)"
                    ) {
                        values.remove(at: index)
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                IconTile(symbol: kind == .domain ? "globe" : "number", size: 22)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if !values.isEmpty {
                    Text("\(values.count) 条")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .onChange(of: input) { _, _ in inputError = nil }
    }

    private func add() {
        let entries = input
            .split { $0 == "," || $0 == "，" || $0.isWhitespace }
            .map(String.init)
        guard !entries.isEmpty else { return }
        var accepted: [String] = []
        for entry in entries {
            guard let value = Self.normalized(entry, kind: kind) else {
                inputError = kind == .cidr
                    ? "「\(entry)」不是有效的 IP 或网段，例如 203.0.113.6 或 192.168.0.0/16"
                    : "「\(entry)」不是有效的域名，例如 example.com 或 *.local"
                return
            }
            if !values.contains(value), !accepted.contains(value) { accepted.append(value) }
        }
        values.append(contentsOf: accepted)
        input = ""
    }

    static func normalized(_ raw: String, kind: Kind) -> String? {
        switch kind {
        case .cidr:
            return CustomRouteRule.normalizedCIDR(raw)
        case .domain:
            let value = RoutingSettings.normalizedBypassDomain(raw)
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_*:"))
            guard !value.isEmpty, value.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
            return value
        }
    }
}

struct RuleTargetGroup: Identifiable {
    let target: String
    let rules: [SubscriptionRule]
    let entryCount: Int
    let ruleSetCount: Int
    let missingRuleSetCount: Int
    var id: String { target }

    init(target: String, rules: [SubscriptionRule], ruleSets: [String: PreparedSubscriptionRuleSet] = [:]) {
        self.target = target
        self.rules = rules
        var entries = 0
        var setCount = 0
        var missing = 0
        for rule in rules {
            guard rule.kind == .ruleSet else {
                entries += 1
                continue
            }
            setCount += 1
            if let prepared = ruleSets[rule.value] {
                entries += prepared.entryCount
            } else {
                missing += 1
            }
        }
        entryCount = entries
        ruleSetCount = setCount
        missingRuleSetCount = missing
    }

    func composition() -> String? {
        guard ruleSetCount > 0 else { return nil }
        let missing = missingRuleSetCount > 0 ? "，\(missingRuleSetCount) 个未下载" : ""
        return "\(ruleSetCount) 个规则集\(missing)"
    }
}

/// 订阅单条规则：在目标小窗与搜索结果小窗中显示。
private struct RuleRow: View {
    @Environment(AppState.self) private var state
    let rule: SubscriptionRule
    let tint: Color
    var showsTarget = true
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(rule.kindDisplayName)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 76, alignment: .leading)
                Text(rule.value)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                if let detail {
                    Text(detail)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                if showsTarget {
                    Text(rule.target)
                        .font(.caption)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            if showsDivider {
                Theme.separator.frame(height: 0.5)
            }
        }
    }

    private var detail: String? {
        switch rule.kind {
        case .single:
            return nil
        case .ruleSet:
            if let prepared = state.activeSubscriptionRuleSets[rule.value] {
                return "\(prepared.entryCount.formatted()) 条"
            }
            return state.isDownloadingActiveRuleSets ? "下载中…" : "未下载"
        case .geoIP:
            return rule.value == "CN" ? "内置国内 IP 库" : "暂不支持，已跳过"
        }
    }
}

/// 小窗中带小号红色删除按钮的规则行：行高 28，无分隔线。
private struct TileRuleRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    var monospaced = false
    var showsDivider: Bool = false
    var isDisabled: Bool = false
    let deleteHelp: String
    let accessibilityLabel: String
    let onDelete: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 14)
            }
            Text(title)
                .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(subtitle)
            }
            Spacer(minLength: 8)
            trailing
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isDisabled ? Theme.textTertiary : Theme.danger.icon)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(deleteHelp)
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(height: 28)
    }
}

extension TileRuleRow where Trailing == EmptyView {
    init(
        symbol: String? = nil,
        title: String,
        subtitle: String? = nil,
        monospaced: Bool = false,
        showsDivider: Bool = false,
        isDisabled: Bool = false,
        deleteHelp: String,
        accessibilityLabel: String,
        onDelete: @escaping () -> Void
    ) {
        self.init(
            symbol: symbol,
            title: title,
            subtitle: subtitle,
            monospaced: monospaced,
            showsDivider: showsDivider,
            isDisabled: isDisabled,
            deleteHelp: deleteHelp,
            accessibilityLabel: accessibilityLabel,
            onDelete: onDelete,
            trailing: { EmptyView() }
        )
    }
}

/// 本机自定义规则条目行：供 BypassListSection 内部使用。
private struct CustomRuleEntryRow: View {
    let symbol: String
    let value: String
    var target: String? = nil
    var targetTint: Color? = nil
    var isDisabled: Bool = false
    let help: String
    let accessibilityLabel: String
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, size: 22)
            Text(value)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if let target {
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.textTertiary)
                Text(target)
                    .font(.callout)
                    .foregroundStyle(targetTint ?? Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isDisabled ? Theme.textTertiary : Theme.danger.icon)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .help(help)
            .accessibilityLabel(accessibilityLabel)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
