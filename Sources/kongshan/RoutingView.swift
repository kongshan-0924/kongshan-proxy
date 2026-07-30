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

    private var activeName: String {
        state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .pageBackground()
        .navigationTitle("规则")
        .onAppear { refreshRunningApps() }
    }

    private var header: some View {
        PageHeader(title: "规则", subtitle: "配置「\(activeName)」自带的分流规则（只读）") {
            HStack(spacing: 12) {
                if state.isApplyingRouting {
                    ProgressView().controlSize(.small)
                }
                Toggle("应用订阅规则", isOn: useSubscriptionRulesBinding)
                Toggle("拦截广告", isOn: blockAdsBinding)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(state.isApplyingRouting)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            perAppSection
            Divider()
            subscriptionRulesContent
        }
    }

    @ViewBuilder
    private var subscriptionRulesContent: some View {
        let all = state.subscriptionRules
        if all.isEmpty {
            ContentUnavailableView {
                Label("当前配置没有自带规则", systemImage: "arrow.triangle.branch")
            } description: {
                Text("仍会套用内置兜底：私有网段与中国大陆直连、其余走代理。切换到带规则的配置可在此查看。")
            }
        } else {
            let keyword = ruleSearch.trimmingCharacters(in: .whitespaces).lowercased()
            let matched = keyword.isEmpty
                ? all
                : all.filter { $0.value.lowercased().contains(keyword) || $0.target.lowercased().contains(keyword) }
            // 分组只算一次：header 的「N 个目标」与下面的列表都要用，
            // 三千多条各分一遍纯属白工。
            let targetGroups = keyword.isEmpty ? groups(of: all) : []
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索规则或目标策略", text: $ruleSearch)
                        .textFieldStyle(.plain)
                    if keyword.isEmpty {
                        Text("\(all.count) 条 · \(targetGroups.count) 个目标")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("匹配 \(matched.count) / \(all.count)")
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
