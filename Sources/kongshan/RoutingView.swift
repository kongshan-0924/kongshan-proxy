import KongshanCore
import SwiftUI

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
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField("搜索规则或目标策略", text: $ruleSearch)
                        .textFieldStyle(.plain)
                    Text("\(all.count) 条")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                Divider()

                List {
                    ForEach(matched.prefix(200)) { rule in
                        HStack(spacing: 10) {
                            Text(rule.type.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 76, alignment: .leading)
                            Text(rule.value)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(rule.target)
                                .font(.caption)
                                .foregroundStyle(targetTint(rule.target))
                        }
                        .padding(.vertical, 1)
                    }
                    if matched.count > 200 {
                        Text("仅显示前 200 条，共 \(matched.count) 条匹配")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
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
            }

            HStack(spacing: 10) {
                Picker("App", selection: $selectedProcess) {
                    if runningApps.isEmpty {
                        Text("没有可选的运行中 App").tag("")
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
