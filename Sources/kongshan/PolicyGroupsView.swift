import KongshanCore
import SwiftUI

/// 代理页。左侧为策略组卡片，右侧上方为当前策略概览卡，下方为成员卡片与节点列表。
/// 视觉语言与首页「链路控制台」一致，整体采用画布底色与纯白描边卡片。
struct PolicyGroupsView: View {
    @Environment(AppState.self) private var state
    @State private var selectedGroupName: String?
    @State private var searchText = ""
    @State private var sortOption: NodeSortOption = .defaultOrder
    @State private var showsTestURLSheet = false

    var body: some View {
        let groups = state.displayPolicyGroups
        let rememberedGroup = selectedGroupName ?? state.proxyPageGroupName
        let currentGroup = groups.first { $0.name == rememberedGroup }
            ?? groups.first
            ?? PolicyGroup(name: "手动选择")
        let options = state.groupOptions(currentGroup)
        let selectedName = state.selectedMemberName(in: currentGroup.name, options: options)
        let isSelectable = currentGroup.kind == .selector

        VStack(alignment: .leading, spacing: 16) {
            // 原型的顶部工具条（出站模式分段 + 搜索）在页内顶栏 .pageTopBar 里，与红绿灯同一行。
            HStack(alignment: .top, spacing: Theme.cardGap) {
                // 左列 224（960 窗口配套从 248 按比例收窄，仍 ≥200）：右侧成员列表留约 492。
                policyGroupCard(groups: groups, currentGroupName: currentGroup.name)
                    .frame(width: 224)

                PolicyMemberList(
                    group: currentGroup,
                    options: options,
                    selectedName: selectedName,
                    isSelectable: isSelectable,
                    searchText: searchText,
                    sortOption: $sortOption
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvasBackground)
        .groupBoxStyle(CardGroupBoxStyle())
        .sheet(isPresented: $showsTestURLSheet) { SpeedTestURLSheet().sheetChrome() }
        .buttonStyle(.pill)
        // 原型：顶部工具条 = 出站模式分段 + 右侧搜索。
        .pageTopBar {
                CapsuleSegmentedPicker(options: OutboundMode.allCases, selection: state.outboundModeBinding) { $0.displayName }
                    .fixedSize()
                    .help(state.outboundMode.detail)
                    .disabled(state.isBusy || !state.isReady)

                Spacer(minLength: 8)

                SpeedTestToolbarButton()

                // 测延迟选项菜单保留测速方式与选最快入口
                Menu {
                    Button("测延迟并选最快") { state.startFastestTest(in: currentGroup.name) }
                        .disabled(state.testableNodes.isEmpty || state.isTestingAllDelays || !isSelectable)
                    Divider()
                    Picker("测延迟方式", selection: state.speedTestMethodBinding) {
                        ForEach(SpeedTestMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.inline)
                    if state.speedTestMethod == .urlTest {
                        Divider()
                        Button("测试地址…") { showsTestURLSheet = true }
                    }
                } label: {
                    Label("测延迟选项", systemImage: "slider.horizontal.3")
                }
                // 必须定宽：无边框菜单会抢占可伸缩空间，真机上被拉成横贯顶栏的一长条——图标贴到左边，
                // 点顶栏空白处弹出的是这个菜单、窗口也拖不动（2026-11-10 iMac 实测，辅助功能里宽 1250）。
                .fixedSize()
                .help("测延迟并选最快，以及怎么测：真实延迟经各节点访问测试地址，代理没开也能测；TCP 握手只测节点服务器能不能连上")

                TopBarSearchField(text: $searchText, prompt: "搜索节点", width: 220)
        }
    }

    // MARK: - 左列：策略组卡

    private func policyGroupCard(groups: [PolicyGroup], currentGroupName: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("策略组")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(groups.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // 少时贴合、多时卡内滚动；只建一份懒加载列表（见 HuggingScrollStack）。
            ScrollViewReader { proxy in
                HuggingScrollStack(alignment: .center, spacing: 2,
                                   estimatedHeight: CGFloat(groups.count) * 46) {
                    policyGroupRows(groups: groups, currentGroupName: currentGroupName)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                .onAppear {
                    proxy.scrollTo(currentGroupName, anchor: .center)
                }
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func policyGroupRows(groups: [PolicyGroup], currentGroupName: String) -> some View {
        ForEach(groups, id: \.name) { group in
            let options = state.groupOptions(group)
            let sub = subtitle(for: group, options: options)
            PolicyGroupRow(
                group: group,
                subtitle: sub,
                isSelected: group.name == currentGroupName,
                onSelect: {
                    selectedGroupName = group.name
                    state.proxyPageGroupName = group.name
                }
            )
            .id(group.name)
        }
    }

    private func subtitle(for group: PolicyGroup, options: [GroupOption]) -> String {
        if group.kind == .urltest { return "自动选路 · \(options.filter(\.isAvailable).count) 个" }
        return state.selectedMemberName(in: group.name, options: options) ?? "未选择"
    }
}

/// 代理页右列容器：包含顶部概览卡与占满剩余高度的成员列表卡。
///
/// 独立视图设计隔离高频刷新状态，确保整页作用域不会观察到延迟回填事件。
private struct PolicyMemberList: View {
    let group: PolicyGroup
    let options: [GroupOption]
    let selectedName: String?
    let isSelectable: Bool
    let searchText: String
    @Binding var sortOption: NodeSortOption

    var body: some View {
        VStack(spacing: Theme.cardGap) {
            PolicyGroupOverviewCard(
                group: group,
                options: options,
                selectedName: selectedName,
                isSelectable: isSelectable
            )

            PolicyMemberCard(
                group: group,
                options: options,
                selectedName: selectedName,
                isSelectable: isSelectable,
                searchText: searchText,
                sortOption: $sortOption
            )
        }
    }
}

// MARK: - 左列策略组单行

/// 策略组单行按钮：左侧 28×28 圆角图标块（支持 emoji 或 SF Symbol）+ 两行文字。
/// 支持悬停状态，并在选中时呈现矿物青浅底与强调色文字。
private struct PolicyGroupRow: View {
    let group: PolicyGroup
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        let (emoji, cleanTitle) = parseGroupTitle(group.name)
        let appearance = groupAppearance(group)

        Button(action: onSelect) {
            HStack(spacing: 10) {
                // 图标块：28×28，r=8；选中时白底+强调色图标，未选中时浅灰底+深灰图标
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Theme.cardFill : Theme.controlFill)
                        .frame(width: 28, height: 28)
                    if let emoji {
                        Text(emoji)
                            .font(.system(size: 14))
                    } else {
                        Image(systemName: appearance)
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    }
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(cleanTitle)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? Theme.selectionFill
                            : isHovering
                            ? Theme.hoverFill
                            : Color.clear
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 右侧：概览卡

/// 右侧顶部概览卡：展示组名、调度状态、当前成员及选最快主操作。
private struct PolicyGroupOverviewCard: View {
    @Environment(AppState.self) private var state
    let group: PolicyGroup
    let options: [GroupOption]
    let selectedName: String?
    let isSelectable: Bool

    var body: some View {
        let (emoji, cleanTitle) = parseGroupTitle(group.name)
        let appearance = groupAppearance(group)
        let totalCount = options.count
        let availableCount = options.filter(\.isAvailable).count

        VStack(alignment: .leading, spacing: 12) {
            // 第一行：图标块 + 组名与类型标签 + 成员统计 + 右侧测延迟操作
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.selectionFill)
                        .frame(width: 36, height: 36)
                    if let emoji {
                        Text(emoji)
                            .font(.system(size: 18))
                    } else {
                        Image(systemName: appearance)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(cleanTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Theme.textSecondary)
                                .frame(width: 5, height: 5)
                            Text(isSelectable ? "手动选择" : "自动选路")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.controlFill, in: Capsule(style: .circular))
                        .fixedSize()
                    }

                    Text("\(totalCount) 个成员 / \(availableCount) 个可用")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer(minLength: 8)

                actionButtons
            }

            Theme.separator.frame(height: 0.5)

            // 第二行：当前节点行
            HStack(spacing: 8) {
                Text("当前节点")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                activeMemberRow
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var activeMemberRow: some View {
        let currentOption = options.first(where: { $0.name == selectedName })
        if let currentOption {
            memberDetail(currentOption)
        } else if let selectedName, !selectedName.isEmpty {
            Text(selectedName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text(isSelectable ? "未选择" : "由内核按延迟自动选择")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func memberDetail(_ option: GroupOption) -> some View {
        switch option {
        case let .node(node):
            let metadata = state.nodeCatalog.metadataByNodeID[node.id] ?? NodeNameMetadata.parse(node.name)
            HStack(spacing: 6) {
                if let flag = metadata.flag, !node.name.contains(flag) {
                    Text(flag)
                }
                Text(node.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProtocolTag(value: node.protocolType)
                DelayLabel(milliseconds: state.delays[node.id])
            }
        case let .reference(refName):
            HStack(spacing: 6) {
                Text(refName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("策略引用")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        case let .unavailable(unName):
            HStack(spacing: 6) {
                Text(unName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("未导入")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }


    /// 「测延迟」对所有组都有用（自动组也要看延迟）；「选最快」只有手动组能选。
    private var actionButtons: some View {
        HStack(spacing: 8) {
            SpeedTestToolbarButton(inCard: true)
                .buttonStyle(.pill)
                .fixedSize()
            if isSelectable {
                fastestButton
            }
        }
    }

    private var fastestButton: some View {
        Button("测延迟并选最快") {
            state.startFastestTest(in: group.name)
        }
        .buttonStyle(.pillProminent)
        .disabled(state.testableNodes.isEmpty || state.isTestingAllDelays)
        .fixedSize()
    }
}

// MARK: - 右侧：成员卡

/// 成员列表卡：包含标题栏统计、排序 / 分组菜单，以及按策略、（可选）地区或协议、未导入分节的原生列表。
private struct PolicyMemberCard: View {
    @Environment(AppState.self) private var state
    let group: PolicyGroup
    let options: [GroupOption]
    let selectedName: String?
    let isSelectable: Bool
    let searchText: String
    @Binding var sortOption: NodeSortOption
    /// 默认不分组（用户要原先的平铺列表），想按地区 / 协议看时在菜单里切，记住选择。
    @AppStorage("proxyPage.nodeGrouping") private var grouping: NodeGroupingOption = .flat

    private struct RegionSection {
        let key: String
        let title: String
        var options: [GroupOption]
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
                case let .reference(name), let .unavailable(name):
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

    private func delayValue(for option: GroupOption, delays: [UUID: Int?]) -> Int {
        guard case let .node(node) = option else { return 999_999 }
        guard let delay = delays[node.id] else { return 888_888 }
        guard let ms = delay else { return 999_000 }
        return ms
    }

    private func optionDelay(_ option: GroupOption, delays: [UUID: Int?]) -> Int?? {
        guard case let .node(node) = option else { return nil }
        return delays[node.id]
    }

    var body: some View {
        let delays = state.delays
        let visibleOptions = processedOptions(options, delays: delays)
        let availableCount = options.filter(\.isAvailable).count

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text("成员")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(options.count) 个 / \(availableCount) 个可用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Menu {
                    Picker("排序", selection: $sortOption) {
                        ForEach(NodeSortOption.allCases) { opt in
                            Label(opt.rawValue, systemImage: opt.symbol).tag(opt)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("分组", selection: $grouping) {
                        ForEach(NodeGroupingOption.allCases) { opt in
                            Text(opt.title).tag(opt)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(grouping == .flat ? "\(sortOption.rawValue) ⌄" : "\(sortOption.rawValue) · \(grouping.title) ⌄")
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if visibleOptions.isEmpty {
                if searchText.isEmpty {
                    TileEmptyNote(text: "当前配置没有节点")
                } else {
                    TileEmptyNote(text: "未找到匹配「\(searchText)」的节点")
                }
            } else {
                // 少时贴合、多时卡内滚动；只建一份懒加载列表。原先「先量不滚动版再建 List」会把 300 个成员
                // 非懒加载地整份建好量一遍，切到代理页要 1 s（2026-11-09 iMac 基准）。
                ScrollViewReader { proxy in
                    HuggingScrollStack(estimatedHeight: CGFloat(visibleOptions.count) * 32) {
                        memberSections(visibleOptions: visibleOptions, delays: delays)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .disabled(state.isBusy)
                    .onAppear { revealRemembered(in: visibleOptions, using: proxy) }
                    .onChange(of: group.name) { _, _ in revealRemembered(in: visibleOptions, using: proxy) }
                }
            }
        }
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func memberSections(visibleOptions: [GroupOption], delays: [UUID: Int?]) -> some View {
        let references = visibleOptions.filter {
            if case .reference = $0 { return true } else { return false }
        }
        let nodes = visibleOptions.filter {
            if case .node = $0 { return true } else { return false }
        }
        let unavailables = visibleOptions.filter {
            if case .unavailable = $0 { return true } else { return false }
        }

        if !references.isEmpty {
            Section {
                ForEach(references) { option in
                    memberRow(option, delays: delays)
                }
            } header: {
                Text("策略")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(nil)
            }
        }

        if grouping != .flat {
            let groupedSections = grouping == .region ? groupNodesByRegion(nodes) : groupNodesByProtocol(nodes)
            ForEach(groupedSections, id: \.key) { sec in
                Section {
                    ForEach(sec.options) { option in
                        memberRow(option, delays: delays)
                    }
                } header: {
                    Text("\(sec.title) / \(sec.options.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .textCase(nil)
                }
            }
        } else if references.isEmpty && unavailables.isEmpty {
            // 只有节点时不加分节头，就是原先的平铺列表。
            ForEach(nodes) { option in
                memberRow(option, delays: delays)
            }
        } else if !nodes.isEmpty {
            Section {
                ForEach(nodes) { option in
                    memberRow(option, delays: delays)
                }
            } header: {
                Text("节点 / \(nodes.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(nil)
            }
        }

        if !unavailables.isEmpty {
            Section {
                ForEach(unavailables) { option in
                    memberRow(option, delays: delays)
                }
            } header: {
                Text("未导入")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .textCase(nil)
            }
        }
    }

    private func groupNodesByProtocol(_ nodes: [GroupOption]) -> [RegionSection] {
        var sections: [RegionSection] = []
        var keyToIndex: [String: Int] = [:]
        for option in nodes {
            guard case let .node(node) = option else { continue }
            let key = node.protocolType.shortName
            if let idx = keyToIndex[key] {
                sections[idx].options.append(option)
            } else {
                keyToIndex[key] = sections.count
                sections.append(RegionSection(key: key, title: key, options: [option]))
            }
        }
        return sections
    }

    private func groupNodesByRegion(_ nodes: [GroupOption]) -> [RegionSection] {
        var sections: [RegionSection] = []
        var otherNodes: [GroupOption] = []
        var keyToIndex: [String: Int] = [:]

        for option in nodes {
            guard case let .node(node) = option else { continue }
            let meta = state.nodeCatalog.metadataByNodeID[node.id] ?? NodeNameMetadata.parse(node.name)
            if let code = meta.regionCode, !code.isEmpty {
                if let idx = keyToIndex[code] {
                    sections[idx].options.append(option)
                } else {
                    let regionName = Locale(identifier: "zh_Hans").localizedString(forRegionCode: code) ?? code
                    let flag = meta.flag ?? ""
                    let title = flag.isEmpty ? regionName : "\(flag) \(regionName)"
                    keyToIndex[code] = sections.count
                    sections.append(RegionSection(key: code, title: title, options: [option]))
                }
            } else {
                otherNodes.append(option)
            }
        }
        if !otherNodes.isEmpty {
            sections.append(RegionSection(key: "other", title: "其他", options: otherNodes))
        }
        return sections
    }

    @ViewBuilder
    private func memberRow(_ option: GroupOption, delays: [UUID: Int?]) -> some View {
        let isSelected = option.name == selectedName
        PolicyMemberRowButton(
            isSelected: isSelected,
            action: {
                guard isSelectable, option.isAvailable else { return }
                state.proxyPageClickedMember[group.name] = option.name
                guard option.name != selectedName else { return }
                Task { await state.select(optionName: option.name, in: group.name) }
            }
        ) {
            optionRowContent(
                option,
                isSelected: isSelected,
                delay: optionDelay(option, delays: delays)
            )
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .id(option.id)
        .help(helpText(for: option, isSelectable: isSelectable))
    }

    private func optionRowContent(
        _ option: GroupOption,
        isSelected: Bool,
        delay: Int??
    ) -> some View {
        let metadata: NodeNameMetadata? = if case let .node(node) = option {
            state.nodeCatalog.metadataByNodeID[node.id] ?? NodeNameMetadata.parse(node.name)
        } else {
            nil
        }

        return HStack(spacing: 8) {
            switch option {
            case let .node(node):
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 10, height: 10)
                } else {
                    Color.clear
                        .frame(width: 10, height: 10)
                }

                if let flag = metadata?.flag, !node.name.contains(flag) {
                    Text(flag)
                }
                Text(option.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        !option.isAvailable
                            ? AnyShapeStyle(Theme.textTertiary)
                            : AnyShapeStyle(Theme.textPrimary)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if let multiplier = metadata?.multiplierText {
                    Text(multiplier)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                        .help("订阅节点倍率")
                }

                // 彩色延迟
                Group {
                    switch delay {
                    case .some(.some), .some(.none):
                        DelayLabel(milliseconds: delay)
                    case .none:
                        Color.clear
                    }
                }
                .frame(width: 60, alignment: .trailing)

                ProtocolTag(value: node.protocolType)

            case let .reference(name):
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 11)
                Text(name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("策略")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

            case let .unavailable(name):
                Color.clear.frame(width: 11, height: 1)
                Text(name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("未导入")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(height: 32)
        .contentShape(Rectangle())
    }

    private func helpText(for option: GroupOption, isSelectable: Bool) -> String {
        if !isSelectable { return "该策略由内核自动选路，不能手动指定" }
        switch option {
        case let .node(node): return "\(node.server):\(node.port)"
        case .reference: return "指向另一个策略 / 直连 / 拒绝"
        case .unavailable: return "订阅里有这个节点，但内核不支持它的协议或传输方式（如 h2、kcp、HTTP/3 的 XHTTP），导入时已跳过，选不了也测不了"
        }
    }

    private func revealRemembered(in visible: [GroupOption], using proxy: ScrollViewProxy) {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wanted = [state.proxyPageClickedMember[group.name], selectedName].compactMap { $0 }
        guard let target = wanted.lazy.compactMap({ name in visible.first { $0.name == name } }).first else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            proxy.scrollTo(target.id, anchor: .center)
        }
    }
}

/// 成员单行按钮：行高 32，无行间分隔线，只靠悬停 / 选中底色区分。
private struct PolicyMemberRowButton<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Theme.selectionFill : (isHovering ? Theme.hoverFill : Color.clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - 工具函数

/// 策略组名开头的 emoji 拆出来当图标（规则见 `IconTile.split`）。
private func parseGroupTitle(_ rawName: String) -> (emoji: String?, cleanTitle: String) {
    let parts = IconTile.split(rawName)
    return (parts.emoji, parts.title)
}

private func groupAppearance(_ group: PolicyGroup) -> String {
    let name = group.name.lowercased()
    if group.kind == .urltest || name.contains("自动") || name.contains("auto") {
        return "antenna.radiowaves.left.and.right"
    }
    if name.contains("故障") || name.contains("fallback") {
        return "arrow.triangle.swap"
    }
    if name.contains("手动") || name.contains("manual") { return "hand.tap.fill" }
    if name.contains("netflix") || name.contains("hbo") || name.contains("disney")
        || name.contains("youtube") || name.contains("bilibili") || name.contains("mytv")
        || name.contains("media") || name.contains("流媒体") {
        return "play.tv.fill"
    }
    if name.contains("telegram") { return "paperplane.fill" }
    if name == "ai" || name.contains("openai") || name.contains("claude")
        || name.contains("gemini") || name.contains("gpt") || name.contains("copilot") {
        return "sparkles"
    }
    if name.contains("github") || name.contains("gitlab") {
        return "chevron.left.forwardslash.chevron.right"
    }
    if name.contains("twitter") || name.contains("x.com") {
        return "bubble.left.and.bubble.right.fill"
    }
    if name.contains("crypto") || name.contains("币") { return "bitcoinsign.circle.fill" }
    if name.contains("steam") || name.contains("epic") || name.contains("xbox")
        || name.contains("playstation") || name.contains("bahamut") || name.contains("游戏") || name.contains("game") {
        return "gamecontroller.fill"
    }
    if name.contains("spotify") || name.contains("music") || name.contains("音乐") {
        return "music.note"
    }
    if name.contains("apple") || name.contains("icloud") { return "apple.logo" }
    if name.contains("google") { return "g.circle.fill" }
    if name.contains("microsoft") || name.contains("onedrive") { return "cloud.fill" }
    if name.contains("direct") || name.contains("直连") { return "arrow.right.circle.fill" }
    if name.contains("reject") || name.contains("广告") || name.contains("adblock") { return "shield.lefthalf.filled" }
    if name.contains("prox") || name.contains("节点") || name.contains("global") { return "globe.asia.australia.fill" }
    return "rectangle.3.group.fill"
}

/// 成员列表的节点分组方式。
enum NodeGroupingOption: String, CaseIterable, Identifiable {
    case flat
    case region
    case protocolType

    var id: Self { self }
    var title: String {
        switch self {
        case .flat: "不分组"
        case .region: "按地区"
        case .protocolType: "按协议"
        }
    }
}

/// 「测延迟全部 / 取消」。测延迟进度每回填一批就变一次，单独成视图才不会带着整页重绘。
private struct SpeedTestToolbarButton: View {
    @Environment(AppState.self) private var state
    /// 概览卡里也放一个：工具栏版只有灰图标，不显眼。⌘R 只能挂一处，卡内版不挂。
    var inCard = false

    var body: some View {
        Button {
            if state.isTestingAllDelays {
                state.cancelDelayTests()
            } else {
                state.startAllDelayTests()
            }
        } label: {
            if inCard {
                Text(state.isTestingAllDelays ? "取消 \(state.speedTestProgress.label)" : "测延迟")
                    .monospacedDigit()
            } else if state.isTestingAllDelays {
                Label("取消 \(state.speedTestProgress.label)", systemImage: "xmark.circle")
            } else {
                Label("测延迟全部", systemImage: "gauge.with.needle")
            }
        }
        .keyboardShortcut(inCard ? nil : KeyboardShortcut("r", modifiers: .command))
        .disabled(state.testableNodes.isEmpty)
        .help(state.isTestingAllDelays ? "取消正在进行的测延迟（⌘R）" : "对当前配置的全部节点测延迟（⌘R）")
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
