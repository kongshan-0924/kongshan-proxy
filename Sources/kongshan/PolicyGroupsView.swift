import KongshanCore
import SwiftUI

/// 代理页。左列是当前配置带出的策略（含内置 手动选择/自动选择），
/// 右列是所选策略的成员：节点显示协议与延迟、可测速；也可能是指向其他策略的引用。
struct PolicyGroupsView: View {
    @Environment(AppState.self) private var state
    @State private var selectedGroupName: String?

    private var currentGroup: PolicyGroup {
        let groups = state.displayPolicyGroups
        return groups.first { $0.name == selectedGroupName } ?? groups.first ?? PolicyGroup(name: "手动选择")
    }

    /// 只有 selector 能手动指定成员；urltest 由内核按测速自动选路。
    private var isSelectable: Bool { currentGroup.kind == .selector }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                groupColumn
                Divider()
                nodeColumn
            }
        }
        .pageBackground()
        .navigationTitle("代理")
    }

    // MARK: - 顶部

    private var header: some View {
        PageHeader(title: "代理", subtitle: "为每个策略选择出站节点；出站模式决定分流是否生效") {
            HStack(spacing: 10) {
                Picker("出站模式", selection: outboundModeBinding) {
                    ForEach(OutboundMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .help(state.outboundMode.detail)
                .disabled(state.isBusy || !state.isReady)

                Button {
                    Task { await state.testAllDelays() }
                } label: {
                    Label(state.isTestingAllDelays ? "测速中…" : "测速全部", systemImage: "gauge.with.dots.needle.67percent")
                }
                .disabled(state.testableNodes.isEmpty || state.isTestingAllDelays)
            }
        }
    }

    // MARK: - 左列：策略

    private var groupColumn: some View {
        List(selection: Binding(get: { currentGroup.name }, set: { selectedGroupName = $0 })) {
            ForEach(state.displayPolicyGroups) { group in
                groupRow(group).tag(group.name)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 230)
    }

    private func groupRow(_ group: PolicyGroup) -> some View {
        HStack(spacing: 9) {
            IconBadge(symbol: groupSymbol(group), tint: groupTint(group), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(subtitle(for: group))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func subtitle(for group: PolicyGroup) -> String {
        if group.kind == .urltest { return "自动选路 · \(state.groupOptions(group).count) 个" }
        return state.selectedMemberName(in: group.name) ?? "未选择"
    }

    private func groupSymbol(_ group: PolicyGroup) -> String {
        switch group.name {
        case "手动选择": "hand.tap"
        case "自动选择": "bolt.badge.automatic"
        default: group.kind == .urltest ? "bolt.badge.automatic" : "rectangle.3.group"
        }
    }

    private func groupTint(_ group: PolicyGroup) -> Color {
        switch group.name {
        case "手动选择": .blue
        case "自动选择": .green
        default: group.kind == .urltest ? .green : .purple
        }
    }

    // MARK: - 右列：成员

    private var nodeColumn: some View {
        ScrollView {
            let options = state.groupOptions(currentGroup)
            if options.isEmpty {
                ContentUnavailableView(
                    "当前配置没有节点",
                    systemImage: "tray",
                    description: Text("请先在「配置」页导入订阅并设为生效。")
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                if !isSelectable {
                    hintBanner("「\(currentGroup.name)」由内核按测速自动选路，无法手动指定。")
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(options) { option in
                        optionCard(option)
                    }
                }
                .padding(18)
            }
        }
    }

    private func hintBanner(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "bolt.badge.automatic")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func optionCard(_ option: GroupOption) -> some View {
        let isSelected = state.isSelected(option, in: currentGroup.name)
        return Button {
            Task { await state.select(optionName: option.name, in: currentGroup.name) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: option, selected: isSelected))
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    Text(option.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    switch option {
                    case let .node(node):
                        ProtocolTag(value: node.protocolType)
                        Text("·").font(.caption2).foregroundStyle(.tertiary)
                        delayBadge(node)
                    case .reference:
                        Text("策略引用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .padding(12)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy || !isSelectable)
        .help(helpText(for: option))
    }

    private func symbol(for option: GroupOption, selected: Bool) -> String {
        if selected { return "checkmark.circle.fill" }
        switch option {
        case .node: return "server.rack"
        case .reference: return "arrow.turn.down.right"
        }
    }

    private func helpText(for option: GroupOption) -> String {
        if !isSelectable { return "该策略由内核自动选路，不能手动指定" }
        switch option {
        case let .node(node): return "\(node.server):\(node.port)"
        case .reference: return "指向另一个策略 / 直连 / 拒绝"
        }
    }

    @ViewBuilder
    private func delayBadge(_ node: ProxyNode) -> some View {
        switch state.delays[node.id] {
        case let .some(.some(value)):
            HStack(spacing: 4) {
                Circle().fill(Theme.delayColor(value)).frame(width: 6, height: 6)
                Text("\(value)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .some(.none):
            Text("超时").font(.caption2).foregroundStyle(.red)
        case .none:
            Text("未测速").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var outboundModeBinding: Binding<OutboundMode> {
        Binding(
            get: { state.outboundMode },
            set: { mode in Task { await state.setOutboundMode(mode) } }
        )
    }
}

extension OutboundMode {
    var symbol: String {
        switch self {
        case .direct: "arrow.right"
        case .rule: "list.bullet"
        case .global: "globe"
        }
    }
}
