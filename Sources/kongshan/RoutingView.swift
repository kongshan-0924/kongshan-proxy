import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 规则页。只读展示当前生效配置带出的分流规则；顶部开关控制是否套用这些规则、是否拦广告。
/// 手动绕过域名/IP 与跳过 TUN 的列表挪到「设置 → 隧道」。
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

    private var activeName: String {
        state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无"
    }

    var body: some View {
        let subscriptionRules = state.subscriptionRules
        VStack(spacing: 0) {
            header(hasSubscriptionRules: !subscriptionRules.isEmpty)
            Divider()
            content(subscriptionRules)
        }
        .pageBackground()
        .navigationTitle("规则")
        .onAppear { refreshRunningApps() }
    }

    private func header(hasSubscriptionRules: Bool) -> some View {
        let subtitle = hasSubscriptionRules
            ? "配置「\(activeName)」自带的分流规则（只读）"
            : "当前配置未提供订阅规则；仍可管理强制代理和分应用代理"
        return PageHeader(title: "规则", subtitle: subtitle) {
            HStack(spacing: 12) {
                if state.isApplyingRouting {
                    ProgressView().controlSize(.small)
                }
                if hasSubscriptionRules {
                    Toggle("应用订阅规则", isOn: useSubscriptionRulesBinding)
                }
                Toggle("拦截广告", isOn: blockAdsBinding)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(state.isApplyingRouting)
        }
    }

    @ViewBuilder
    private func content(_ subscriptionRules: [SubscriptionRule]) -> some View {
        VStack(spacing: 0) {
            perAppSection
            Divider()
            forcedProxySection
            Divider()
            sshProxySection
            Divider()
            routeTesterSection
            Divider()
            subscriptionRulesContent(subscriptionRules)
        }
    }

    @ViewBuilder
    private func subscriptionRulesContent(_ rules: [SubscriptionRule]) -> some View {
        if rules.isEmpty {
            ContentUnavailableView {
                Label("当前配置没有自带规则", systemImage: "arrow.triangle.branch")
            } description: {
                Text("仍会套用内置兜底：私有网段与中国大陆直连、其余走代理。切换到带规则的配置可在此查看。")
            }
        } else {
            let keyword = ruleSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let matched = keyword.isEmpty
                ? rules
                : rules.filter { $0.value.lowercased().contains(keyword) || $0.target.lowercased().contains(keyword) }
            // 分组只算一次：header 的「N 个目标」与下面的列表都要用，
            // 三千多条各分一遍纯属白工。
            let targetGroups = keyword.isEmpty ? groups(of: rules) : []
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索规则或目标策略", text: $ruleSearch)
                        .textFieldStyle(.plain)
                    if keyword.isEmpty {
                        Text("\(rules.count) 条 · \(targetGroups.count) 个目标")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("匹配 \(matched.count) / \(rules.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                Divider()

                // 搜索时给扁平结果（用户已经在找具体一条）；不搜索时按目标策略折叠。
                // 三千多条规则平铺出来既没有全局认知、也找不到东西——用户真正想知道的是
                // "哪些流量走哪个策略"，那正是按 target 分组的形状。
                if keyword.isEmpty {
                    List {
                        ForEach(targetGroups) { group in
                            RuleTargetGroupRow(group: group, tint: targetTint(group.target))
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                } else {
                    List {
                        ForEach(matched.prefix(300)) { rule in
                            RuleRow(rule: rule, tint: targetTint(rule.target))
                        }
                        if matched.count > 300 {
                            Text("仅显示前 300 条，共 \(matched.count) 条匹配——把关键词写得更具体些")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
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

    private var perAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("分应用代理", systemImage: "app.badge.checkmark")
                    .font(.system(size: 13, weight: .semibold))
                Text("按可执行进程名优先分流")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refreshRunningApps()
                } label: {
                    Label("刷新 App", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                Button {
                    chooseInstalledApp()
                } label: {
                    Label("选择已安装 App", systemImage: "folder")
                }
                .controlSize(.small)
            }

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
                .frame(maxWidth: 300)

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
                .frame(maxWidth: 300)

                Button {
                    addPerAppRule()
                } label: {
                    Label("添加 / 更新", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedProcess.isEmpty || state.isApplyingRouting)
                Spacer(minLength: 0)
            }

            if state.processRules.isEmpty {
                Text("还没有分应用规则。选择一个正在运行的 App 后添加。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(state.processRules) { rule in
                            HStack(spacing: 6) {
                                Text(rule.value)
                                    .font(.caption.monospaced())
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Text(state.processRuleTargetName(rule))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(rule.action == .direct ? .green : .accentColor)
                                Button(role: .destructive) {
                                    Task { await state.removeProcessRule(rule.id) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.cardFill, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var forcedProxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("强制代理", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .semibold))
                Text("规则模式下优先于订阅规则和中国大陆直连")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                Picker("类型", selection: $forcedProxyKind) {
                    ForEach(ForcedProxyInputKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)

                TextEditor(text: $forcedProxyInput)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 58)
                    .padding(.horizontal, 6)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }

                Button {
                    addForcedProxyRule()
                } label: {
                    Label("批量应用", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    forcedProxyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || state.isApplyingRouting
                )
            }

            Text("可用空格、逗号或换行分隔多个目标；整批校验通过后只重载一次内核，现有连接会在重载时断开。")
                .font(.caption2)
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
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(state.forcedProxyRules) { rule in
                            HStack(spacing: 6) {
                                Image(systemName: rule.type == .ipCIDR ? "network" : "globe")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(rule.value)
                                    .font(.caption.monospaced())
                                Button(role: .destructive) {
                                    Task { await state.removeForcedProxyRule(rule.id) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(state.isApplyingRouting)
                                .help("删除强制代理规则")
                                .accessibilityLabel("删除 \(rule.value)")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.cardFill, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
        .onChange(of: forcedProxyKind) { _, _ in forcedProxyError = nil }
        .onChange(of: forcedProxyInput) { _, _ in forcedProxyError = nil }
    }

    private var sshProxySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("SSH 走代理", systemImage: "terminal")
                    .font(.system(size: 13, weight: .semibold))
                Text("指定 IP 的 OpenSSH 连接通过当前节点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            HStack(spacing: 10) {
                TextField("IP 地址", text: $sshProxyAddress)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addSSHProxyTarget() }
                TextField("端口", value: $sshProxyPort, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 92)
                    .onSubmit { addSSHProxyTarget() }
                Button {
                    addSSHProxyTarget()
                } label: {
                    Label("添加", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    sshProxyAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || state.isApplyingRouting
                )
            }

            Text("规则保存在本机，开启代理后生效；只修改空山托管的 SSH 配置片段，不会读取或保存 SSH 密码、私钥。")
                .font(.caption2)
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
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(state.sshProxyTargets) { target in
                            HStack(spacing: 6) {
                                Image(systemName: "network")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text("\(target.address):\(target.port)")
                                    .font(.caption.monospaced())
                                Button(role: .destructive) {
                                    Task { await state.removeSSHProxyTarget(target) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .disabled(state.isApplyingRouting)
                                .help("删除 SSH 代理目标")
                                .accessibilityLabel("删除 \(target.address):\(target.port)")
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Theme.cardFill, in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.16))
        .onChange(of: sshProxyAddress) { _, _ in sshProxyError = nil }
        .onChange(of: sshProxyPort) { _, _ in sshProxyError = nil }
    }

    private var routeTesterSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("规则命中测试", systemImage: "scope")
                    .font(.system(size: 13, weight: .semibold))
                Text("按实际生成顺序解释本地可判定规则")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Picker("输入类型", selection: $routeTestKind) {
                    ForEach(RouteTestKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                TextField(routeTestKind.placeholder, text: $routeTestInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { runRouteTest() }
                Button {
                    runRouteTest()
                } label: {
                    Label("测试", systemImage: "play.fill")
                }
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
                .font(.caption.monospaced())
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.12))
        .onChange(of: routeTestKind) { _, _ in routeTestResult = nil }
        .onChange(of: routeTestInput) { _, _ in routeTestResult = nil }
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
                        .font(.system(.body, design: .monospaced))
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

/// 同一目标策略下的规则集合。
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
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(group.target)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(group.rules.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(tint.opacity(0.12), in: Capsule())
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
                        .font(.caption2)
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
                .font(.system(.caption, design: .monospaced))
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
