import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 规则页：自定义 / 订阅 两个分段。
///
/// 2026-09-17 之前这一页是 `VSplitView`——上半可改的表单、下半只读的订阅规则。
/// 两半的自然高度差得太远：表单五个分区全展开要六百多点才不截断，订阅规则有三千条要能翻。
/// 于是分割线放哪都有一半难受，**表单总被切在某张分区卡片中间**（SSH 那张常年只露半行标题），
/// 而配置不带订阅规则时下半屏整屏都是空状态。用户 09-17 反馈「布局有些别扭」指的就是这个。
///
/// 改成 `.principal` 分段后任意时刻只有一个子视图，各自吃满窗口高度；
/// 与 诊断 / 连接 / 日志 三页同形。两个子视图都留在本文件：
/// `NativeChromeGuardTests` 按文件名核对 `.navigationSubtitle` 与 `.searchable` 的存在。
struct RoutingView: View {
    enum Tab: String, CaseIterable {
        case custom = "自定义"
        case subscription = "订阅"
    }

    @Environment(AppState.self) private var state
    @State private var tab: Tab = .custom
    @State private var showsRuleSetSheet = false

    var body: some View {
        // 结构化 switch 而不是 ZStack + opacity：订阅分段那张列表要按目标分组三千条规则，
        // 常驻会让它在自定义分段也跟着当前配置重算。
        Group {
            switch tab {
            case .custom: CustomRoutingRulesView()
            case .subscription: SubscriptionRulesBrowserView()
            }
        }
        .navigationTitle("规则")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("规则来源", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                // 命中测试搬去诊断页了，但产生「这条流量为什么走那里」疑问的现场仍是这一页。
                // 给一键跳转而不是一句不可点的提示文字。
                Button {
                    state.requestPage(.diagnostics)
                } label: {
                    Label("命中测试", systemImage: "scope")
                }
                .help("到诊断页测试某个域名 / IP / 进程会命中哪条规则")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsRuleSetSheet = true
                } label: {
                    Label("数据库", systemImage: "cylinder.split.1x2")
                }
                .help("GeoIP 与规则集的下载源、自动更新与立即更新")
            }
        }
        .sheet(isPresented: $showsRuleSetSheet) { RuleSetDatabaseSheet() }
    }
}

// MARK: - 自定义分段

/// 本机自定义的四类规则 + 拦截广告开关。这些都存在 `routingSettings` 里、与当前生效的
/// 订阅配置无关，所以副标题不提配置名——提了会让人以为换配置就换一套。
struct CustomRoutingRulesView: View {
    @Environment(AppState.self) private var state
    /// `RoutingSettings` 的唯一草稿持有者。见 `bypassSection` 的说明。
    @State private var routingDraft = RoutingSettings.defaults
    @State private var runningApps: [AppState.RunningApp] = []
    @State private var selectedProcess = ""
    @State private var perAppTarget: PerAppTarget = .proxy
    @State private var forcedProxyKind: ForcedProxyInputKind = .domain
    @State private var forcedProxyInput = ""
    @State private var forcedProxyError: String?
    @State private var sshProxyAddress = ""
    @State private var sshProxyPort = 22
    @State private var sshProxyError: String?
    // 分区折叠状态跨会话记忆。分段化之后表单能吃满整个窗口高度，
    // 四个分区默认全展开也不会互相挤掉——SSH 低频，仍默认收起。
    @AppStorage("routing.perApp.expanded") private var perAppExpanded = true
    @AppStorage("routing.forcedProxy.expanded") private var forcedProxyExpanded = true
    @AppStorage("routing.bypass.expanded") private var bypassExpanded = false
    @AppStorage("routing.sshProxy.expanded") private var sshProxyExpanded = false

    var body: some View {
        Form {
            switchesSection
            perAppSection
            forcedProxySection
            bypassSection
            sshProxySection
        }
        .formStyle(.grouped)
        .navigationSubtitle(subtitle)
        .onAppear {
            refreshRunningApps()
            routingDraft = state.routingSettings
        }
        // 只在草稿未脏时跟随外部变化：脏着就同步会把用户没应用完的编辑冲掉。
        .onChange(of: state.routingSettings) { old, new in
            if routingDraft == old { routingDraft = new }
        }
    }

    /// 四类规则各多少条。全 0 时说一句人话，不摆一排「0」。
    private var subtitle: String {
        let counts = [
            ("分应用", state.processRules.count),
            ("强制代理", state.forcedProxyRules.count),
            ("强制直连", routingDraft.bypassDomains.count + routingDraft.bypassCIDRs.count),
            ("SSH", state.sshProxyTargets.count),
        ].filter { $0.1 > 0 }
        guard !counts.isEmpty else { return "本机自定义规则 · 还没有任何一条" }
        return counts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    // MARK: - 规则开关

    private var switchesSection: some View {
        Section {
            Toggle("拦截广告", isOn: blockAdsBinding)
        } header: {
            HStack {
                Text("规则")
                if state.isApplyingRouting {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            Text("拦截广告用规则集屏蔽广告域名。下面四类规则都存在本机，不随订阅更新变化；订阅自带的规则在「订阅」分段。")
        }
        .disabled(state.isApplyingRouting)
    }

    // MARK: - 分应用代理

    private var perAppSection: some View {
        Section(isExpanded: $perAppExpanded) {
            // 两行：主操作（选 App、选走向、添加）一行；两个辅助入口另起一行并说明用途。
            // 此前五个控件挤一行，App 名在普通窗宽下就被截成「"企业微信"网页内容…」。
            HStack(spacing: 10) {
                Picker("App", selection: $selectedProcess) {
                    if runningApps.isEmpty {
                        Text("没有可选 App").tag("")
                    } else {
                        ForEach(runningApps) { app in
                            Text("\(app.name)（\(app.processName)）").tag(app.processName)
                        }
                    }
                }
                .labelsHidden()
                .frame(minWidth: 180, maxWidth: 360)

                Picker("走向", selection: $perAppTarget) {
                    Text("直连").tag(PerAppTarget.direct)
                    Text("默认代理").tag(PerAppTarget.proxy)
                    if !state.testableNodes.isEmpty {
                        Divider()
                        ForEach(state.testableNodes) { node in
                            let flag = NodeNameMetadata.parse(node.name).flag.map { "\($0) " } ?? ""
                            Text("指定：\(flag)\(node.name)").tag(PerAppTarget.node(node.id))
                        }
                    }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 260)

                Spacer(minLength: 0)

                Button("添加 / 更新") { addPerAppRule() }
                    .disabled(selectedProcess.isEmpty || state.isApplyingRouting)
            }

            HStack(spacing: 8) {
                Text("列表只含正在运行的 App；没在跑的用「选择已安装 App…」。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                Button("刷新 App") { refreshRunningApps() }
                    .controlSize(.small)
                Button("选择已安装 App…") { chooseInstalledApp() }
                    .controlSize(.small)
            }

            if state.processRules.isEmpty {
                Text("还没有分应用规则。选择一个正在运行的 App 后添加。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(state.processRules) { rule in
                    HStack(spacing: 8) {
                        Text(rule.value)
                            .font(.body.monospaced())
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(state.processRuleTargetName(rule))
                            .foregroundStyle(rule.action == .direct ? .green : .accentColor)
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            Task { await state.removeProcessRule(rule.id) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("删除该 App 的分流规则")
                        .accessibilityLabel("删除 \(rule.value)")
                    }
                }
            }
        } header: {
            sectionHeader("分应用代理", symbol: "app.badge.checkmark",
                          hint: "按可执行进程名优先分流", count: state.processRules.count, expanded: perAppExpanded)
        }
    }

    // MARK: - 强制代理

    private var forcedProxySection: some View {
        Section(isExpanded: $forcedProxyExpanded) {
            HStack(alignment: .top, spacing: 10) {
                Picker("类型", selection: $forcedProxyKind) {
                    ForEach(ForcedProxyInputKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                TextField(forcedProxyKind.placeholder, text: $forcedProxyInput,
                          prompt: Text(forcedProxyKind.placeholder), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .font(.body.monospaced())

                Button("批量应用") { addForcedProxyRule() }
                    .disabled(
                        forcedProxyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || state.isApplyingRouting
                    )
            }

            Text("可用空格、逗号或换行分隔多个目标；整批校验通过后只重载一次内核，现有连接会在重载时断开。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let forcedProxyError {
                Label(forcedProxyError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if state.forcedProxyRules.isEmpty {
                Text("暂无强制代理目标")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(state.forcedProxyRules) { rule in
                    HStack(spacing: 8) {
                        Image(systemName: rule.type == .ipCIDR ? "network" : "globe")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(rule.value)
                            .font(.body.monospaced())
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            Task { await state.removeForcedProxyRule(rule.id) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(state.isApplyingRouting)
                        .help("删除强制代理规则")
                        .accessibilityLabel("删除 \(rule.value)")
                    }
                }
            }
        } header: {
            sectionHeader("强制代理", symbol: "arrow.up.forward.app",
                          hint: "规则模式下优先于订阅规则和中国大陆直连", count: state.forcedProxyRules.count, expanded: forcedProxyExpanded)
        }
        .onChange(of: forcedProxyKind) { _, _ in forcedProxyError = nil }
        .onChange(of: forcedProxyInput) { _, _ in forcedProxyError = nil }
    }

    // MARK: - 强制直连与排除

    /// 迁自 设置→隧道·绕过列表。
    ///
    /// 这三张表本来就是分流规则——`bypassDomains` / `bypassCIDRs` / `tunExcludeCIDRs`
    /// 同属 `RoutingSettings` 一个结构体、由同一个 `applyRoutingSettings` 写回，
    /// 与本页其余分区是同一件事的两面（那边说「强制走代理」，这边说「强制直连」）。
    /// 它此前住在设置页只是历史原因。
    ///
    /// **本页是 `RoutingSettings` 草稿的唯一持有者**：设置页原先也有一份 `routingDraft`
    /// 并且无条件 `onChange` 同步，两处同时编辑会互相覆盖。搬过来后那份已删除。
    private var bypassSection: some View {
        Section(isExpanded: $bypassExpanded) {
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
                // 必须显式应用：改一个字符就重载内核会掐断所有连接。
                Button("应用并重载内核") {
                    Task { await state.applyRoutingSettings(routingDraft) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || routingDraft == state.routingSettings)
            }
        } header: {
            sectionHeader("强制直连与排除", symbol: "arrow.uturn.down",
                          hint: "同时生效于分流规则、系统代理 bypass 与 TUN 排除",
                          count: routingDraft.bypassDomains.count + routingDraft.bypassCIDRs.count,
                          expanded: bypassExpanded)
        }
    }

    // MARK: - SSH 走代理

    private var sshProxySection: some View {
        Section(isExpanded: $sshProxyExpanded) {
            HStack(spacing: 10) {
                TextField("IP 地址", text: $sshProxyAddress, prompt: Text("IP 地址"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit { addSSHProxyTarget() }
                TextField("端口", value: $sshProxyPort,
                          format: .number.grouping(.never), prompt: Text("端口"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 92)
                    .onSubmit { addSSHProxyTarget() }
                Button("添加") { addSSHProxyTarget() }
                    .disabled(
                        sshProxyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || state.isApplyingRouting
                    )
            }

            Text("规则保存在本机，开启代理后生效；只修改空山托管的 SSH 配置片段，不会读取或保存 SSH 密码、私钥。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let sshProxyError {
                Label(sshProxyError, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if state.sshProxyTargets.isEmpty {
                Text("暂无 SSH 代理目标")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(state.sshProxyTargets) { target in
                    HStack(spacing: 8) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text("\(target.address):\(target.port)")
                            .font(.body.monospaced())
                        Spacer(minLength: 8)
                        Button(role: .destructive) {
                            Task { await state.removeSSHProxyTarget(target) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(state.isApplyingRouting)
                        .help("删除 SSH 代理目标")
                        .accessibilityLabel("删除 \(target.address):\(target.port)")
                    }
                }
            }
        } header: {
            sectionHeader("SSH 走代理", symbol: "terminal",
                          hint: "指定 IP 的 OpenSSH 连接通过当前节点", count: state.sshProxyTargets.count, expanded: sshProxyExpanded)
        }
        .onChange(of: sshProxyAddress) { _, _ in sshProxyError = nil }
        .onChange(of: sshProxyPort) { _, _ in sshProxyError = nil }
    }

    /// 分区标题：符号 + 名称 + 一句说明；折叠时把条目数留在标题行，不用展开也能看到有多少条。
    private func sectionHeader(_ title: String, symbol: String, hint: String, count: Int, expanded: Bool) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
            Text(hint)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if count > 0, !expanded {
                Text("\(count) 条")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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

/// 当前生效配置带出的分流规则，只读。顶部一条窄栏放「应用订阅规则」总开关——
/// 这个开关管的就是这一屏的东西，放在自定义分段里反而要跨段理解。
struct SubscriptionRulesBrowserView: View {
    @Environment(AppState.self) private var state
    @State private var ruleSearch = ""
    /// 仅供离屏渲染自查：分组全部展开。
    var expandsAllGroups = false

    private var activeName: String {
        state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无"
    }

    var body: some View {
        let subscriptionRules = state.subscriptionRules
        let keyword = ruleSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = keyword.isEmpty
            ? subscriptionRules
            : subscriptionRules.filter { $0.value.lowercased().contains(keyword) || $0.target.lowercased().contains(keyword) }
        // 分组只算一次：副标题的「N 个目标」与下面的列表都要用，三千多条各分一遍纯属白工。
        let targetGroups = keyword.isEmpty ? groups(of: subscriptionRules) : []

        let ruleSetNames = Self.ruleSetNames(in: subscriptionRules)

        VStack(spacing: 0) {
            if !subscriptionRules.isEmpty {
                toggleBar
                Divider()
            }
            if !ruleSetNames.isEmpty {
                ruleSetBar(names: ruleSetNames)
                Divider()
            }
            subscriptionRulesContent(subscriptionRules, matched: matched, targetGroups: targetGroups, keyword: keyword)
        }
        .navigationSubtitle(subtitle(
            total: subscriptionRules.count, matched: matched.count, groups: targetGroups.count,
            ruleSets: ruleSetNames.count, keyword: keyword
        ))
        .searchable(text: $ruleSearch, placement: .toolbar, prompt: "搜索规则或目标策略")
    }

    /// 与代理页「由内核自动选路」那条同形的窄栏：开关 + 一句说明，不占一整张 Form 卡片。
    private var toggleBar: some View {
        HStack(spacing: 10) {
            Toggle("应用订阅规则", isOn: useSubscriptionRulesBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
            if state.isApplyingRouting {
                ProgressView().controlSize(.mini)
            }
            Text("来自配置「\(activeName)」，只读；关掉后仍套用内置兜底（私有网段与中国大陆直连，其余走代理）。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .disabled(state.isApplyingRouting)
    }

    private func subtitle(total: Int, matched: Int, groups: Int, ruleSets: Int, keyword: String) -> String {
        guard total > 0 else { return "当前配置未提供订阅规则" }
        if keyword.isEmpty {
            let sets = ruleSets > 0 ? " · 含 \(ruleSets) 个规则集" : ""
            return "配置「\(activeName)」· \(total) 条规则\(sets) · \(groups) 个目标"
        }
        return "匹配 \(matched) / \(total) 条"
    }

    /// 被引用的规则集名，按订阅里的顺序、去重。
    private static func ruleSetNames(in rules: [SubscriptionRule]) -> [String] {
        var seen = Set<String>()
        return rules.filter { $0.kind == .ruleSet && seen.insert($0.value).inserted }.map(\.value)
    }

    /// 规则集状态：下载了几份、共多少条、最早一份何时更新。缺的在后台下载，也可手动重下——
    /// 内核会自动重载被替换的规则集文件，更新不用重启、不断连接。
    private func ruleSetBar(names: [String]) -> some View {
        let sets = state.activeSubscriptionRuleSets
        let ready = names.filter { sets[$0] != nil }
        let entries = ready.reduce(0) { $0 + (sets[$1]?.entryCount ?? 0) }
        let oldest = ready.compactMap { sets[$0]?.fetchedAt }.min()
        return HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ready.count == names.count
                 ? "规则集 \(names.count) 个 · 共 \(entries.formatted()) 条"
                 : "规则集已下载 \(ready.count) / \(names.count) 个 · 共 \(entries.formatted()) 条")
                .font(.caption)
            if let oldest {
                Text("最早一份更新于 \(oldest.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if state.isDownloadingActiveRuleSets {
                ProgressView().controlSize(.mini)
                Text("正在下载…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("立即更新") {
                    Task { await state.updateSubscriptionRuleSetsNow() }
                }
                .controlSize(.small)
                .help("重新下载当前配置的全部规则集；下载失败的沿用已有缓存")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - 规则浏览

    @ViewBuilder
    private func subscriptionRulesContent(
        _ rules: [SubscriptionRule],
        matched: [SubscriptionRule],
        targetGroups: [RuleTargetGroup],
        keyword: String
    ) -> some View {
        if rules.isEmpty {
            ContentUnavailableView {
                Label("当前配置没有自带规则", systemImage: "arrow.triangle.branch")
            } description: {
                Text("仍会套用内置兜底：私有网段与中国大陆直连、其余走代理。切换到带规则的配置可在此查看。")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if keyword.isEmpty {
            // 不搜索时按目标策略折叠：三千多条规则平铺出来既没有全局认知、也找不到东西——
            // 用户真正想知道的是"哪些流量走哪个策略"，那正是按 target 分组的形状。
            List {
                Section {
                    ForEach(targetGroups) { group in
                        RuleTargetGroupRow(
                            group: group, tint: targetTint(group.target), initiallyExpanded: expandsAllGroups
                        )
                    }
                } header: {
                    Text("订阅规则 · 只读 · 按目标策略分组")
                } footer: {
                    // MATCH 不是一条可匹配的规则，而是「以上都没命中时」的出口——单独说清楚去向。
                    if state.routingSettings.useSubscriptionRules, let match = state.activeMatchTarget {
                        Text("以上都没命中的流量（MATCH）→ \(match)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            // 搜索时给扁平结果（用户已经在找具体一条）。
            List {
                Section("匹配的订阅规则 · 只读") {
                    ForEach(matched.prefix(300)) { rule in
                        RuleRow(rule: rule, tint: targetTint(rule.target))
                    }
                }
                if matched.count > 300 {
                    Text("仅显示前 300 条，共 \(matched.count) 条匹配——把关键词写得更具体些")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset)
            .overlay {
                if matched.isEmpty { ContentUnavailableView.search(text: ruleSearch) }
            }
        }
    }

    /// 按目标策略分组，条目多的在前。用户扫这一屏就知道流量大致怎么分的。
    /// 一条 `RULE-SET` 背后可能是几万条，所以按展开后的条目数排，而不是按规则条数。
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

    private func targetTint(_ target: String) -> Color {
        switch target.uppercased() {
        case "DIRECT": .green
        case "REJECT", "REJECT-DROP": .red
        default: .accentColor
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


/// 可增删的字符串列表（绕过域名 / IP / 跳过 TUN 网段）。设置页的隧道分区复用。
/// 两个列表结构一致时，用带前缀的显式 id 把行身份分开，避免 SwiftUI 串内容。
struct BypassListSection: View {
    let title: String
    let placeholder: String
    let addTitle: String
    let deleteHelp: String
    let identity: String
    @Binding var values: [String]

    var body: some View {
        Section(title) {
            if values.isEmpty {
                Text("暂无，点下方添加")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    // 用 prompt 而非 label 作占位：只在空行显示提示，填了值就正常左对齐，
                    // 不再有「例如…」那一列常驻标签。
                    TextField(placeholder, text: $values[index], prompt: Text(placeholder))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                    Button(role: .destructive) {
                        values.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(deleteHelp)
                }
                .id("\(identity)-\(index)")
            }
            Button {
                values.append("")
            } label: {
                Label(addTitle, systemImage: "plus")
            }
        }
    }
}

struct RuleTargetGroup: Identifiable {
    let target: String
    let rules: [SubscriptionRule]
    /// 流向这个目标的条目数：单条规则算一条，规则集按已下载的条数算。
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
}

/// 折叠的目标策略组。默认收起——一屏看完"流量怎么分"，需要细看再展开。
private struct RuleTargetGroupRow: View {
    let group: RuleTargetGroup
    let tint: Color
    @State private var isExpanded: Bool

    init(group: RuleTargetGroup, tint: Color, initiallyExpanded: Bool = false) {
        self.group = group
        self.tint = tint
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    /// 组里有规则集时说明构成：右侧的数字是展开后的条目数，不是规则条数。
    private var composition: String? {
        guard group.ruleSetCount > 0 else { return nil }
        let missing = group.missingRuleSetCount > 0 ? "，\(group.missingRuleSetCount) 个未下载" : ""
        return "\(group.ruleSetCount) 个规则集\(missing)"
    }

    /// 展开后仍然限量：单个组也可能有上千条，全铺出来一样卡。
    /// 但**必须把被省掉的条数说出来**，静默截断会让人以为规则就这么多。
    private static let expandedLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    // 目标策略的颜色放在色点上，名字用正文色：整行彩色粗体像一列链接和警告，
                    // 访达的标签就是"色点 + 普通文字"。
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                    Text(group.target)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let composition {
                        Text(composition)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Text(group.entryCount.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(group.rules.prefix(Self.expandedLimit)) { rule in
                    // 组内不重复显示目标策略：组头已经写了，每行再挂一遍纯粹是噪音。
                    RuleRow(rule: rule, tint: tint, showsTarget: false)
                        .padding(.leading, 20)
                }
                if group.rules.count > Self.expandedLimit {
                    Text("还有 \(group.rules.count - Self.expandedLimit) 条未显示，用上方搜索定位")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                        .padding(.vertical, 3)
                }
            }
        }
    }
}

/// 单条规则。分组展开与搜索结果共用同一行样式。
private struct RuleRow: View {
    @Environment(AppState.self) private var state
    let rule: SubscriptionRule
    let tint: Color
    /// 搜索结果里必须显示目标（结果是跨组混在一起的）；组内展开时省掉。
    var showsTarget = true

    var body: some View {
        HStack(spacing: 10) {
            Text(rule.kindDisplayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(rule.value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if showsTarget {
                Text(rule.target)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .padding(.vertical, 1)
    }

    /// 规则集显示条数（没下载时说明状态）；GEOIP 说明由谁判定。
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
