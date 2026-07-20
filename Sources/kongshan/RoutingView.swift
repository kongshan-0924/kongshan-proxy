import KongshanCore
import SwiftUI

struct RoutingView: View {
    @Environment(AppState.self) private var state
    @State private var draft = RoutingSettings.defaults

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                customRulesSection
                bypassDomainsSection
                bypassCIDRsSection
                optionsSection
            }
            .listStyle(.inset)
        }
        .navigationTitle("规则")
        .onAppear { draft = state.routingSettings }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("分流规则")
                    .font(.title2.weight(.semibold))
                Text("自定义规则优先级最高；修改会统一校验并应用到内核与系统绕过列表。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isApplyingRouting {
                ProgressView()
                    .controlSize(.small)
                Text("正在应用…")
                    .foregroundStyle(.secondary)
            }
            Button("放弃更改") { draft = state.routingSettings }
                .disabled(state.isBusy || draft == state.routingSettings)
            Button("应用规则") { apply() }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || draft == state.routingSettings)
        }
        .padding()
    }

    private var customRulesSection: some View {
        Section {
            ForEach($draft.customRules) { $rule in
                CustomRuleRow(
                    rule: $rule,
                    proxyGroups: availableProxyGroups,
                    onDelete: { removeRule(id: rule.id) }
                )
            }
            .onMove(perform: moveRules)

            Button {
                addRule()
            } label: {
                Label("添加自定义规则", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("自定义规则")
                Spacer()
                Text("可拖拽排序")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("从上到下依次匹配；关闭的规则会保存，但不会写入运行配置。")
        }
    }

    private var bypassDomainsSection: some View {
        Section("绕过域名") {
            ForEach(draft.bypassDomains.indices, id: \.self) { index in
                HStack {
                    TextField("例如 *.local 或 example.com", text: $draft.bypassDomains[index])
                    Button(role: .destructive) {
                        draft.bypassDomains.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除域名")
                }
            }
            Button {
                draft.bypassDomains.append("")
            } label: {
                Label("添加域名", systemImage: "plus")
            }
        }
    }

    private var bypassCIDRsSection: some View {
        Section("绕过 IP / CIDR") {
            ForEach(draft.bypassCIDRs.indices, id: \.self) { index in
                HStack {
                    TextField("例如 192.168.0.0/16", text: $draft.bypassCIDRs[index])
                    Button(role: .destructive) {
                        draft.bypassCIDRs.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("删除 CIDR")
                }
            }
            Button {
                draft.bypassCIDRs.append("")
            } label: {
                Label("添加 IP / CIDR", systemImage: "plus")
            }
        }
    }

    private var optionsSection: some View {
        Section("选项") {
            Toggle("拦截常见广告域名", isOn: $draft.blockAds)
            Text("关闭时不会下载或加载广告规则集。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("恢复默认绕过列表") {
                draft.bypassDomains = RoutingSettings.defaults.bypassDomains
                draft.bypassCIDRs = RoutingSettings.defaults.bypassCIDRs
            }
        }
    }

    private var availableProxyGroups: [String] {
        var groups = ["自动选择", "手动选择"]
        if !state.manualNodes.isEmpty { groups.append("自建") }
        return groups
    }

    private func addRule() {
        draft.customRules.append(CustomRouteRule(
            order: draft.customRules.count,
            type: .domainSuffix,
            value: "",
            action: .proxy,
            proxyGroup: "自动选择"
        ))
    }

    private func removeRule(id: UUID) {
        draft.customRules.removeAll { $0.id == id }
        normalizeRuleOrder()
    }

    private func moveRules(from offsets: IndexSet, to destination: Int) {
        draft.customRules.move(fromOffsets: offsets, toOffset: destination)
        normalizeRuleOrder()
    }

    private func normalizeRuleOrder() {
        for index in draft.customRules.indices { draft.customRules[index].order = index }
    }

    private func apply() {
        normalizeRuleOrder()
        Task { await state.applyRoutingSettings(draft) }
    }
}

private struct CustomRuleRow: View {
    @Binding var rule: CustomRouteRule
    let proxyGroups: [String]
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Toggle("启用", isOn: $rule.enabled)
                .labelsHidden()
                .help(rule.enabled ? "停用规则" : "启用规则")
            Picker("类型", selection: $rule.type) {
                ForEach(CustomRuleType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            TextField("匹配值", text: $rule.value)
                .textFieldStyle(.roundedBorder)
            Picker("动作", selection: $rule.action) {
                ForEach(RouteAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 82)
            if rule.action == .proxy {
                Picker("策略组", selection: proxyGroupBinding) {
                    ForEach(proxyGroups, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除规则")
        }
        .padding(.vertical, 3)
    }

    private var proxyGroupBinding: Binding<String> {
        Binding(
            get: {
                guard let group = rule.proxyGroup, proxyGroups.contains(group) else {
                    return proxyGroups.first ?? "自动选择"
                }
                return group
            },
            set: { rule.proxyGroup = $0 }
        )
    }
}
