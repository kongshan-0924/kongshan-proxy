import KongshanCore
import SwiftUI

/// 规则页。只读展示当前生效配置带出的分流规则；顶部开关控制是否套用这些规则、是否拦广告。
/// 手动绕过域名/IP 与跳过 TUN 的列表挪到「设置 → 隧道」。
struct RoutingView: View {
    @Environment(AppState.self) private var state
    @State private var ruleSearch = ""

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
