import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 规则页。上半是低频配置表单（原生 grouped Form，四个分区可折叠），
/// 下半只读展示当前生效配置带出的分流规则。手动绕过域名/IP 与跳过 TUN 的列表在「设置 → 隧道」。
struct RoutingView: View {
    @Environment(AppState.self) private var state
    @State private var ruleSearch = ""
    @State private var runningApps: [AppState.RunningApp] = []
    @State private var selectedProcess = ""
    @State private var perAppTarget: PerAppTarget = .proxy
    @State private var forcedProxyKind: ForcedProxyInputKind = .domain
    @State private var forcedProxyInput = ""
    @State private var forcedProxyError: String?
    @State private var sshProxyAddress = ""
    @State private var sshProxyPort = 22
    @State private var sshProxyError: String?
    @State private var routeTestKind: RouteTestKind = .domain
    @State private var routeTestInput = ""
    @State private var routeTestResult: RouteTestResult?
    // 分区折叠状态跨会话记忆：SSH / 命中测试低频，默认收起，
    // 把纵向空间让给下面真正常看的规则浏览器。
    @AppStorage("routing.perApp.expanded") private var perAppExpanded = true
    @AppStorage("routing.forcedProxy.expanded") private var forcedProxyExpanded = true
    @AppStorage("routing.sshProxy.expanded") private var sshProxyExpanded = false
    @AppStorage("routing.routeTester.expanded") private var routeTesterExpanded = false

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

        GeometryReader { proxy in
            VStack(spacing: 0) {
                // 上半部分是低频配置表单：封顶 55% 高度。
                // 四个分区全展开也不会把规则浏览器挤没；折叠后规则列表自动长大。
                Form {
                    switchesSection(hasSubscriptionRules: !subscriptionRules.isEmpty)
                    perAppSection
                    forcedProxySection
                    sshProxySection
                    routeTesterSection
                }
                .formStyle(.grouped)
                .frame(maxHeight: proxy.size.height * 0.55)
                Divider()
                subscriptionRulesContent(subscriptionRules, matched: matched, targetGroups: targetGroups, keyword: keyword)
            }
        }
        .navigationTitle("规则")
        .navigationSubtitle(subtitle(total: subscriptionRules.count, matched: matched.count, groups: targetGroups.count, keyword: keyword))
        .searchable(text: $ruleSearch, placement: .toolbar, prompt: "搜索规则或目标策略")
        .onAppear { refreshRunningApps() }
    }

    private func subtitle(total: Int, matched: Int, groups: Int, keyword: String) -> String {
        guard total > 0 else { return "当前配置未提供订阅规则" }
        if keyword.isEmpty { return "配置「\(activeName)」· \(total) 条规则 · \(groups) 个目标" }
        return "匹配 \(matched) / \(total) 条"
    }

    // MARK: - 规则开关

    private func switchesSection(hasSubscriptionRules: Bool) -> some View {
        Section {
            if hasSubscriptionRules {
                Toggle("应用订阅规则", isOn: useSubscriptionRulesBinding)
            }
            Toggle("拦截广告", isOn: blockAdsBinding)
        } header: {
            HStack {
                Text("规则")
                if state.isApplyingRouting {
                    ProgressView().controlSize(.mini)
                }
            }
        } footer: {
            Text(hasSubscriptionRules
                 ? "订阅规则来自配置「\(activeName)」，只读；关掉后仍套用内置兜底（私有网段与中国大陆直连，其余走代理）。"
                 : "当前配置未提供订阅规则，仍套用内置兜底；强制代理与分应用代理照常可用。")
        }
        .disabled(state.isApplyingRouting)
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
            // 分区标题说明这半屏是什么：上面是可改的表单，下面是只读的订阅规则，
            // 之前两者之间只有一条分隔线，读者得靠猜。
            List {
                Section("订阅规则 · 只读 · 按目标策略分组") {
                    ForEach(targetGroups) { group in
                        RuleTargetGroupRow(group: group, tint: targetTint(group.target))
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

    /// 按目标策略分组，条数多的在前。用户扫这一屏就知道流量大致怎么分的。
    private func groups(of rules: [SubscriptionRule]) -> [RuleTargetGroup] {
        var order: [String] = []
        var buckets: [String: [SubscriptionRule]] = [:]
        for rule in rules {
            if buckets[rule.target] == nil { order.append(rule.target) }
            buckets[rule.target, default: []].append(rule)
        }
        return order
            .map { RuleTargetGroup(target: $0, rules: buckets[$0] ?? []) }
            .sorted { $0.rules.count > $1.rules.count }
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

                TextField(forcedProxyKind.placeholder, text: $forcedProxyInput, axis: .vertical)
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

    // MARK: - SSH 走代理

    private var sshProxySection: some View {
        Section(isExpanded: $sshProxyExpanded) {
            HStack(spacing: 10) {
                TextField("IP 地址", text: $sshProxyAddress)
                    .font(.body.monospaced())
                    .onSubmit { addSSHProxyTarget() }
                TextField("端口", value: $sshProxyPort, format: .number.grouping(.never))
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

    // MARK: - 规则命中测试

    private var routeTesterSection: some View {
        Section(isExpanded: $routeTesterExpanded) {
            HStack(spacing: 10) {
                Picker("输入类型", selection: $routeTestKind) {
                    ForEach(RouteTestKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                TextField(routeTestKind.placeholder, text: $routeTestInput)
                    .font(.body.monospaced())
                    .onSubmit { runRouteTest() }
                Button("测试") { runRouteTest() }
                    .disabled(routeTestInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let result = routeTestResult {
                HStack(spacing: 14) {
                    Label(result.source.rawValue, systemImage: "checkmark.seal.fill")
                    Text("优先级 \(result.priority)")
                    Text(result.action.displayName)
                        .foregroundStyle(result.action == .direct ? .green : result.action == .reject ? .red : .accentColor)
                    Text("→ \(result.target)")
                    Text("命中：\(result.matchedValue)")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.callout.monospaced())
            }
        } header: {
            sectionHeader("规则命中测试", symbol: "scope",
                          hint: "按实际生成顺序解释本地可判定规则", count: 0, expanded: routeTesterExpanded)
        }
        .onChange(of: routeTestKind) { _, _ in routeTestResult = nil }
        .onChange(of: routeTestInput) { _, _ in routeTestResult = nil }
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

    private func runRouteTest() {
        let value = routeTestInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        routeTestResult = state.testRoute(
            domain: routeTestKind == .domain ? value : nil,
            ip: routeTestKind == .ip ? value : nil,
            processName: routeTestKind == .process ? value : nil
        )
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

    private func targetTint(_ target: String) -> Color {
        switch target.uppercased() {
        case "DIRECT": .green
        case "REJECT", "REJECT-DROP": .red
        default: .accentColor
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

private enum RouteTestKind: String, CaseIterable, Identifiable {
    case domain
    case ip
    case process

    var id: Self { self }
    var title: String {
        switch self {
        case .domain: "域名"
        case .ip: "IP"
        case .process: "进程"
        }
    }
    var placeholder: String {
        switch self {
        case .domain: "api.example.com"
        case .ip: "203.0.113.8"
        case .process: "Safari"
        }
    }
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
    var id: String { target }
}

/// 折叠的目标策略组。默认收起——一屏看完"流量怎么分"，需要细看再展开。
private struct RuleTargetGroupRow: View {
    let group: RuleTargetGroup
    let tint: Color
    @State private var isExpanded = false

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
                    Text("\(group.rules.count)")
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
    let rule: SubscriptionRule
    let tint: Color
    /// 搜索结果里必须显示目标（结果是跨组混在一起的）；组内展开时省掉。
    var showsTarget = true

    var body: some View {
        HStack(spacing: 10) {
            Text(rule.type.displayName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(rule.value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if showsTarget {
                Text(rule.target)
                    .font(.caption)
                    .foregroundStyle(tint)
            }
        }
        .padding(.vertical, 1)
    }
}
