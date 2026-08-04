import KongshanCore
import SwiftUI

/// 代理页。左列是当前配置带出的策略（含内置 手动选择/自动选择），
/// 右列是所选策略的成员：节点显示协议与延迟、可测速；也可能是指向其他策略的引用。
struct PolicyGroupsView: View {
    @Environment(AppState.self) private var state
    @State private var selectedGroupName: String?
    @State private var searchText = ""
    @State private var sortOption: NodeSortOption = .defaultOrder

    var body: some View {
        let groups = state.displayPolicyGroups
        let currentGroup = groups.first { $0.name == selectedGroupName }
            ?? groups.first
            ?? PolicyGroup(name: "手动选择")
        let options = state.groupOptions(currentGroup)
        let selectedName = state.selectedMemberName(in: currentGroup.name, options: options)
        let delays = state.delays
        let isSelectable = currentGroup.kind == .selector

        VStack(spacing: 0) {
            header(currentGroup: currentGroup, isSelectable: isSelectable)
            Divider()
            HStack(spacing: 0) {
                groupColumn(groups: groups, currentGroupName: currentGroup.name)
                Divider()
                nodeColumn(
                    currentGroup: currentGroup,
                    options: options,
                    selectedName: selectedName,
                    delays: delays,
                    isSelectable: isSelectable
                )
            }
        }
        .pageBackground()
        .navigationTitle("代理")
    }

    // MARK: - 顶部

    private func header(currentGroup: PolicyGroup, isSelectable: Bool) -> some View {
        PageHeader(title: "代理", subtitle: "为每个策略选择出站节点；出站模式决定分流是否生效") {
            HStack(spacing: 10) {
                Picker("出站模式", selection: outboundModeBinding) {
                    ForEach(OutboundMode.allCases, id: \.self) { mode in
                        Label(mode.displayName, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .help(state.outboundMode.detail)
                .disabled(state.isBusy || !state.isReady)

                Button {
                    Task { await state.testAllDelays() }
                } label: {
                    Label(state.isTestingAllDelays ? "测速中…" : "测速全部", systemImage: "gauge.with.dots.needle.67percent")
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(state.testableNodes.isEmpty || state.isTestingAllDelays)

                Button {
                    Task { await state.testAndSelectFastest(in: currentGroup.name) }
                } label: {
                    Label("测速并选最快", systemImage: "bolt.badge.checkmark")
                }
                .fixedSize(horizontal: true, vertical: false)
                .disabled(
                    state.testableNodes.isEmpty
                        || state.isTestingAllDelays
                        || !isSelectable
                )
                .help(isSelectable ? "测速完成后自动选择当前策略中延迟最低的节点" : "自动策略由内核选择")
            }
        }
    }

    // MARK: - 左列：策略

    private func groupColumn(groups: [PolicyGroup], currentGroupName: String) -> some View {
        List(selection: Binding(get: { currentGroupName }, set: { selectedGroupName = $0 })) {
            ForEach(groups, id: \.name) { group in
                groupRow(group).tag(group.name)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .frame(width: 230)
    }

    private func groupRow(_ group: PolicyGroup) -> some View {
        let appearance = groupAppearance(group)
        return HStack(spacing: 9) {
            Image(systemName: appearance.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(appearance.tint)
                .frame(width: 18)
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
        let options = state.groupOptions(group)
        if group.kind == .urltest { return "自动选路 · \(options.count) 个" }
        return state.selectedMemberName(in: group.name, options: options) ?? "未选择"
    }

    private func groupAppearance(_ group: PolicyGroup) -> (symbol: String, tint: Color) {
        let name = group.name.lowercased()
        if group.kind == .urltest || name.contains("自动") || name.contains("auto") {
            return ("bolt.badge.automatic", .green)
        }
        if name.contains("手动") { return ("hand.tap", .blue) }
        if name.contains("netflix") || name.contains("hbo") || name.contains("disney")
            || name.contains("youtube") || name.contains("bilibili") || name.contains("mytv") {
            return ("play.tv.fill", .red)
        }
        if name.contains("telegram") { return ("paperplane.fill", .blue) }
        if name == "ai" || name.contains("openai") || name.contains("claude") || name.contains("gemini") {
            return ("brain.head.profile", .mint)
        }
        if name.contains("crypto") || name.contains("币") { return ("bitcoinsign.circle.fill", .orange) }
        if name.contains("steam") || name.contains("epic") || name.contains("xbox")
            || name.contains("playstation") || name.contains("bahamut") || name.contains("游戏") {
            return ("gamecontroller.fill", .indigo)
        }
        if name.contains("spotify") || name.contains("music") || name.contains("音乐") {
            return ("music.note", .green)
        }
        if name.contains("apple") || name.contains("icloud") { return ("apple.logo", .primary) }
        if name.contains("microsoft") || name.contains("onedrive") { return ("cloud.fill", .blue) }
        if name.contains("direct") || name.contains("直连") { return ("arrow.right.circle.fill", .green) }
        if name.contains("prox") || name.contains("节点") { return ("point.3.connected.trianglepath.dotted", .purple) }
        return ("rectangle.3.group", .purple)
    }

    private func processedOptions(
        _ options: [GroupOption],
        delays: [UUID: Int?]
    ) -> [GroupOption] {
        var result = options

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { option in
                switch option {
                case let .node(node):
                    return node.name.localizedCaseInsensitiveContains(query)
                        || node.server.localizedCaseInsensitiveContains(query)
                case let .reference(name):
                    return name.localizedCaseInsensitiveContains(query)
                }
            }
        }

        switch sortOption {
        case .defaultOrder:
            break
        case .nameAscending:
            result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .latencyAscending:
            result.sort { opt1, opt2 in
                delayValue(for: opt1, delays: delays) < delayValue(for: opt2, delays: delays)
            }
        }
        return result
    }

    // MARK: - 右列：成员

    private func delayValue(for option: GroupOption, delays: [UUID: Int?]) -> Int {
        guard case let .node(node) = option else { return 999_999 }
        guard let delay = delays[node.id] else { return 888_888 }
        guard let ms = delay else { return 999_000 }
        return ms
    }

    private func nodeColumn(
        currentGroup: PolicyGroup,
        options: [GroupOption],
        selectedName: String?,
        delays: [UUID: Int?],
        isSelectable: Bool
    ) -> some View {
        VStack(spacing: 0) {
            // 工具条：搜索框 + 排序菜单
            HStack(spacing: 10) {
                SearchField(text: $searchText, placeholder: "搜索节点或域名…")
                    .frame(maxWidth: 260)
                Spacer()
                Menu {
                    Picker("排序", selection: $sortOption) {
                        ForEach(NodeSortOption.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.symbol).tag(opt)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sortOption.symbol)
                        Text(sortOption.rawValue)
                    }
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

            Divider()

            ScrollView {
                let visibleOptions = processedOptions(options, delays: delays)
                if visibleOptions.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "当前配置没有节点" : "未匹配到相关节点",
                        systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                        description: Text(searchText.isEmpty ? "请先在「配置」页导入订阅并设为生效。" : "请尝试搜索其他关键字。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 240)
                } else {
                    if !isSelectable {
                        hintBanner("「\(currentGroup.name)」由内核按测速自动选路，无法手动指定。")
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(visibleOptions) { option in
                            optionCard(
                                option,
                                in: currentGroup.name,
                                selectedName: selectedName,
                                delay: optionDelay(option, delays: delays),
                                isSelectable: isSelectable
                            )
                        }
                    }
                    .padding(18)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func optionDelay(_ option: GroupOption, delays: [UUID: Int?]) -> Int?? {
        guard case let .node(node) = option else { return nil }
        return delays[node.id]
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

    private func optionCard(
        _ option: GroupOption,
        in groupName: String,
        selectedName: String?,
        delay: Int??,
        isSelectable: Bool
    ) -> some View {
        let isSelected = option.name == selectedName
        let metadata: NodeNameMetadata? = if case let .node(node) = option {
            NodeNameMetadata.parse(node.name)
        } else {
            nil
        }
        return Button {
            Task { await state.select(optionName: option.name, in: groupName) }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol(for: option, selected: isSelected))
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    if case let .node(node) = option,
                       let flag = metadata?.flag,
                       !node.name.contains(flag) {
                        Text(flag)
                            .font(.system(size: 15))
                    }
                    Text(option.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    // 延迟提到右上角。这是用户扫一屏节点时唯一要找的数字，
                    // 原本挤在下面一排小标签的末尾，得逐张卡片看过去才能比较。
                    if case .node = option {
                        delayBadge(delay)
                    }
                }
                HStack(spacing: 6) {
                    switch option {
                    case let .node(node):
                        ProtocolTag(value: node.protocolType)
                        if let multiplier = metadata?.multiplierText {
                            Text(multiplier)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .help("订阅节点倍率")
                        }
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
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.09)) : AnyShapeStyle(Theme.cardFill),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy || !isSelectable)
        .help(helpText(for: option, isSelectable: isSelectable))
    }

    private func symbol(for option: GroupOption, selected: Bool) -> String {
        if selected { return "checkmark.circle.fill" }
        switch option {
        case .node: return "server.rack"
        case .reference: return "arrow.turn.down.right"
        }
    }

    private func helpText(for option: GroupOption, isSelectable: Bool) -> String {
        if !isSelectable { return "该策略由内核自动选路，不能手动指定" }
        switch option {
        case let .node(node): return "\(node.server):\(node.port)"
        case .reference: return "指向另一个策略 / 直连 / 拒绝"
        }
    }

    @ViewBuilder
    private func delayBadge(_ delay: Int??) -> some View {
        switch delay {
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
