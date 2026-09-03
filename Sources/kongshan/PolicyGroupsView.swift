import KongshanCore
import SwiftUI

/// 代理页。左列是当前配置带出的策略（含内置 手动选择/自动选择），
/// 右列是所选策略的成员：节点显示协议与延迟、可测速；也可能是指向其他策略的引用。
///
/// 成员用**列表选中即切换**：Surge / ClashX 都是一行一个节点、点一下就选，
/// 不是卡片网格。列表是 AppKit 承载的，上百个节点每秒刷延迟也不重排整屏。
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

        HStack(spacing: 0) {
            groupColumn(groups: groups, currentGroupName: currentGroup.name)
            Divider()
            memberColumn(
                currentGroup: currentGroup,
                options: options,
                selectedName: selectedName,
                delays: delays,
                isSelectable: isSelectable
            )
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("代理")
        .navigationSubtitle(subtitle(currentGroup: currentGroup, optionCount: options.count, selectedName: selectedName))
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索节点")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("出站模式", selection: outboundModeBinding) {
                    ForEach(OutboundMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help(state.outboundMode.detail)
                .disabled(state.isBusy || !state.isReady)

                Menu {
                    Picker("排序", selection: $sortOption) {
                        ForEach(NodeSortOption.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.symbol).tag(opt)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("排序", systemImage: "arrow.up.arrow.down")
                }
                .help("节点排序：\(sortOption.rawValue)")

                Button {
                    if state.isTestingAllDelays {
                        state.cancelDelayTests()
                    } else {
                        state.startAllDelayTests()
                    }
                } label: {
                    if state.isTestingAllDelays {
                        Label("取消 \(state.speedTestProgress.label)", systemImage: "xmark.circle")
                    } else {
                        Label("测速全部", systemImage: "gauge.with.needle")
                    }
                }
                .disabled(state.testableNodes.isEmpty)
                .help(state.isTestingAllDelays ? "取消正在进行的测速" : "对当前配置的全部节点测速")

                Button {
                    state.startFastestTest(in: currentGroup.name)
                } label: {
                    Label("测速并选最快", systemImage: "bolt.badge.checkmark")
                }
                .disabled(state.testableNodes.isEmpty || state.isTestingAllDelays || !isSelectable)
                .help(isSelectable ? "测速完成后自动选择当前策略中延迟最低的节点" : "自动策略由内核选择")
            }
        }
    }

    private func subtitle(currentGroup: PolicyGroup, optionCount: Int, selectedName: String?) -> String {
        var parts = ["\(currentGroup.name) · \(optionCount) 个"]
        if currentGroup.kind == .urltest {
            parts.append("自动选路")
        } else if let selectedName {
            parts.append("当前：\(selectedName)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 左列：策略

    private func groupColumn(groups: [PolicyGroup], currentGroupName: String) -> some View {
        List(selection: Binding(get: { currentGroupName }, set: { selectedGroupName = $0 })) {
            ForEach(groups, id: \.name) { group in
                groupRow(group).tag(group.name)
            }
        }
        // **不用 `.sidebar`**：那个样式会画侧栏的半透明材质，而这里已经嵌在 detail 里，
        // 于是整列渲染成一块灰底，跟右侧白色列表撞得很难看（用户 2026-09-03 的反馈）。
        // 窗口左侧那个才是真正的侧栏；这里是第二层列表，用 `.inset` 与右列同形，
        // 靠中间的 Divider 分隔——邮件的「邮箱 / 邮件列表」两列就是这个关系。
        .listStyle(.inset)
        // 弹性列宽：窗口拖宽时让位给右侧成员列表，拖窄时收缩但不低于 190。
        .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
    }

    private func groupRow(_ group: PolicyGroup) -> some View {
        let appearance = groupAppearance(group)
        return HStack(spacing: 9) {
            Image(systemName: appearance.symbol)
                .foregroundStyle(appearance.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .lineLimit(1)
                Text(subtitle(for: group))
                    .font(.caption)
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
            return ("antenna.radiowaves.left.and.right", .green)
        }
        if name.contains("故障") || name.contains("fallback") {
            return ("arrow.triangle.swap", .orange)
        }
        if name.contains("手动") || name.contains("manual") { return ("hand.tap.fill", .blue) }
        if name.contains("netflix") || name.contains("hbo") || name.contains("disney")
            || name.contains("youtube") || name.contains("bilibili") || name.contains("mytv")
            || name.contains("media") || name.contains("流媒体") {
            return ("play.tv.fill", .red)
        }
        if name.contains("telegram") { return ("paperplane.fill", .cyan) }
        if name == "ai" || name.contains("openai") || name.contains("claude")
            || name.contains("gemini") || name.contains("gpt") || name.contains("copilot") {
            return ("sparkles", .mint)
        }
        if name.contains("github") || name.contains("gitlab") {
            return ("chevron.left.forwardslash.chevron.right", .primary)
        }
        if name.contains("twitter") || name.contains("x.com") {
            return ("bubble.left.and.bubble.right.fill", .blue)
        }
        if name.contains("crypto") || name.contains("币") { return ("bitcoinsign.circle.fill", .orange) }
        if name.contains("steam") || name.contains("epic") || name.contains("xbox")
            || name.contains("playstation") || name.contains("bahamut") || name.contains("游戏") || name.contains("game") {
            return ("gamecontroller.fill", .indigo)
        }
        if name.contains("spotify") || name.contains("music") || name.contains("音乐") {
            return ("music.note", .green)
        }
        if name.contains("apple") || name.contains("icloud") { return ("apple.logo", .primary) }
        if name.contains("google") { return ("g.circle.fill", .blue) }
        if name.contains("microsoft") || name.contains("onedrive") { return ("cloud.fill", .blue) }
        if name.contains("direct") || name.contains("直连") { return ("arrow.right.circle.fill", .green) }
        if name.contains("reject") || name.contains("广告") || name.contains("adblock") { return ("shield.lefthalf.filled", .red) }
        if name.contains("prox") || name.contains("节点") || name.contains("global") { return ("globe.asia.australia.fill", .purple) }
        return ("rectangle.3.group.fill", .purple)
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

    private func memberColumn(
        currentGroup: PolicyGroup,
        options: [GroupOption],
        selectedName: String?,
        delays: [UUID: Int?],
        isSelectable: Bool
    ) -> some View {
        let visibleOptions = processedOptions(options, delays: delays)
        // 选中即切换。不可选（内核自动选路）时给一个只读的常量绑定，列表不响应点击。
        let selection = Binding<String?>(
            get: { selectedName },
            set: { name in
                guard isSelectable, let name, name != selectedName else { return }
                Task { await state.select(optionName: name, in: currentGroup.name) }
            }
        )
        return VStack(spacing: 0) {
            if !isSelectable {
                HStack(spacing: 7) {
                    Image(systemName: "bolt.badge.automatic")
                        .foregroundStyle(.secondary)
                    Text("「\(currentGroup.name)」由内核按测速自动选路，无法手动指定。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            List(selection: selection) {
                ForEach(visibleOptions) { option in
                    optionRow(
                        option,
                        isSelected: option.name == selectedName,
                        delay: optionDelay(option, delays: delays),
                        isSelectable: isSelectable
                    )
                    .tag(option.name)
                }
            }
            // 不用交替行底色：节点通常只有几条到几十条，交替条纹会一路铺到列表底部，
            // 空白处画出一排"幽灵行"，也正是用户反馈「代理这一列比较暗」的来源。
            .listStyle(.inset)
            .disabled(state.isBusy)
            .overlay {
                if visibleOptions.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "当前配置没有节点",
                            systemImage: "tray",
                            description: Text("请先在「配置」页导入订阅并设为生效。")
                        )
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
    }

    private func optionDelay(_ option: GroupOption, delays: [UUID: Int?]) -> Int?? {
        guard case let .node(node) = option else { return nil }
        return delays[node.id]
    }

    private func optionRow(
        _ option: GroupOption,
        isSelected: Bool,
        delay: Int??,
        isSelectable: Bool
    ) -> some View {
        let metadata: NodeNameMetadata? = if case let .node(node) = option {
            NodeNameMetadata.parse(node.name)
        } else {
            nil
        }
        return HStack(spacing: 8) {
            // 只给选中行放标记，其余留空——菜单里的单选项就是这样；一屏几十个一样的机架符号只是噪音。
            if let symbol = symbol(for: option, selected: isSelected) {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .frame(width: 16)
            } else {
                Color.clear.frame(width: 16, height: 1)
            }
            if case let .node(node) = option,
               let flag = metadata?.flag,
               !node.name.contains(flag) {
                Text(flag)
            }
            Text(option.name)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            switch option {
            case let .node(node):
                if let multiplier = metadata?.multiplierText {
                    Text(multiplier)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .help("订阅节点倍率")
                }
                ProtocolTag(value: node.protocolType)
                // 延迟固定在行末：它是用户扫一屏节点时唯一要找的数字，定宽保证一列对齐。
                delayLabel(delay)
                    .frame(width: 64, alignment: .trailing)
            case .reference:
                Text("策略引用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(helpText(for: option, isSelectable: isSelectable))
    }

    private func symbol(for option: GroupOption, selected: Bool) -> String? {
        if selected { return "checkmark.circle.fill" }
        switch option {
        case .node: return nil
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
    private func delayLabel(_ delay: Int??) -> some View {
        switch delay {
        case let .some(.some(value)):
            let color = Theme.delayColor(value)
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
                Text("\(value) ms")
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(color)
            }
        case .some(.none):
            Label("超时", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .none:
            Text("未测速")
                .font(.caption)
                .foregroundStyle(.tertiary)
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
