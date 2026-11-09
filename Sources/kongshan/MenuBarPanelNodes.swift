import AppKit
import KongshanCore
import SwiftUI

// MARK: - 目录纯函数与值模型
enum MenuBarPanelDirectory {
    static func nodePrecedes(_ left: ProxyNode, _ right: ProxyNode) -> Bool {
        let order = left.name.localizedStandardCompare(right.name)
        return order == .orderedSame ? left.id.uuidString < right.id.uuidString : order == .orderedAscending
    }

    static func regionName(_ code: String) -> String {
        // zh_CN 区域名里港澳台是「中国香港特别行政区」这类全称，菜单宽 256 放不下，按原型用简称。
        switch code.uppercased() {
        case "": return "其他"
        case "HK": return "香港"
        case "MO": return "澳门"
        case "TW": return "台湾"
        default: return Locale(identifier: "zh_CN").localizedString(forRegionCode: code) ?? code
        }
    }

    /// 菜单里的节点名：去掉国旗 emoji（地区已用中文名前缀表达，原型不显示国旗），
    /// 名字本身已以地区名开头（如「日本家宽 12」）时不再重复前缀；地区未知时只显示原名。
    static func nodeTitle(_ name: String, regionCode: String) -> String {
        let scalars = name.unicodeScalars.filter { !(0x1F1E6...0x1F1FF).contains($0.value) }
        let stripped = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        let base = stripped.isEmpty ? name : stripped
        guard !regionCode.isEmpty else { return base }
        let region = regionName(regionCode)
        return base.hasPrefix(region) ? base : region + " " + base
    }

    static func regionCodes(in buckets: [String: [ProxyNode]]) -> [String] {
        let locale = Locale(identifier: "zh_CN")
        return buckets.keys.sorted { left, right in
            if left.isEmpty || right.isEmpty { return !left.isEmpty }
            let leftCount = buckets[left]!.count
            let rightCount = buckets[right]!.count
            if leftCount != rightCount { return leftCount > rightCount }
            let order = regionName(left).compare(regionName(right), locale: locale)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
    }
}

struct MenuBarPanelRegion: Identifiable {
    let id: String
    let nodes: [ProxyNode]
    var name: String { MenuBarPanelDirectory.regionName(id) }
}

struct MenuBarPanelNodeEntry: Identifiable {
    enum Content {
        case heading(String)
        case option(GroupOption)
        case region(MenuBarPanelRegion)
    }
    let id: String
    let content: Content
}

// MARK: - 节点目录快照

struct MenuBarPanelNodeSnapshot {
    let group: PolicyGroup
    let selected: String?
    let metadata: [UUID: NodeNameMetadata]
    let entries: [MenuBarPanelNodeEntry]
    var isReadOnly: Bool { group.kind == .urltest }
    var title: String { group.name + (isReadOnly ? " · 自动选路" : "") }

    // 打开这一层才取目录与延迟快照；排序在会话内固定，测速只回填叶子，不把鼠标下的行挪走。
    @MainActor init(state: AppState, group: PolicyGroup, region: MenuBarPanelRegion? = nil) {
        self.group = group
        let metadata = state.nodeCatalog.metadataByNodeID
        self.metadata = metadata
        var seen = Set<String>()
        let options = state.groupOptions(group).filter { seen.insert($0.id).inserted }
        let selected = state.selectedMemberName(in: group.name, options: options)
        self.selected = selected
        if let region {
            entries = region.nodes.sorted(by: MenuBarPanelDirectory.nodePrecedes).map {
                MenuBarPanelNodeEntry(id: $0.id.uuidString, content: .option(.node($0)))
            }
            return
        }
        guard options.count > 20 else {
            entries = options.map { MenuBarPanelNodeEntry(id: $0.id, content: .option($0)) }
            return
        }
        var result: [MenuBarPanelNodeEntry] = []
        func heading(_ title: String) {
            result.append(.init(id: "heading:" + title, content: .heading(title)))
        }
        func append(_ option: GroupOption, prefix: String) {
            result.append(.init(id: prefix + option.id, content: .option(option)))
        }
        if let current = options.first(where: { $0.name == selected }) {
            heading("当前节点")
            append(current, prefix: "current:")
        }
        let nodes = options.compactMap { option -> ProxyNode? in
            if case let .node(node) = option { return node }
            return nil
        }
        let measured = nodes.compactMap { node -> (ProxyNode, Int)? in
            guard node.name != selected, case let .some(.some(delay)) = state.delays[node.id] else { return nil }
            return (node, delay)
        }.sorted { left, right in
            left.1 == right.1 ? MenuBarPanelDirectory.nodePrecedes(left.0, right.0) : left.1 < right.1
        }.prefix(5)
        if !measured.isEmpty {
            heading("低延迟")
            for (node, _) in measured { append(.node(node), prefix: "fast:") }
        }
        let references = options.filter {
            if case .node = $0 { return false }
            return $0.name != selected
        }
        if !references.isEmpty {
            heading("策略")
            for option in references { append(option, prefix: "reference:") }
        }
        let buckets = Dictionary(grouping: nodes) { metadata[$0.id]?.regionCode ?? "" }
        if !buckets.isEmpty {
            heading("按地区")
            for code in MenuBarPanelDirectory.regionCodes(in: buckets) {
                result.append(.init(id: "region:" + code, content: .region(.init(id: code, nodes: buckets[code]!))))
            }
        }
        entries = result
    }

    func title(for option: GroupOption) -> String {
        guard case let .node(node) = option else { return option.name }
        return MenuBarPanelDirectory.nodeTitle(node.name, regionCode: metadata[node.id]?.regionCode ?? "")
    }

    func canSelect(_ option: GroupOption, busy: Bool) -> Bool {
        !isReadOnly && option.isAvailable && !busy
    }

    var contentHeight: CGFloat {
        entries.reduce(0) { value, entry in
            if case .heading = entry.content { return value + MenuBarPanelMetrics.headingHeight }
            return value + MenuBarPanelMetrics.rowStep
        }
    }
    var height: CGFloat { MenuBarPanelMetrics.subChrome + min(MenuBarPanelMetrics.listMaxHeight, max(MenuBarPanelMetrics.rowHeight, contentHeight - MenuBarPanelMetrics.rowGap)) }
}

// MARK: - 子面板与高频叶子视图
struct MenuBarPanelNodesView: View {
    let snapshot: MenuBarPanelNodeSnapshot
    let level: Int
    let controller: MenuBarPanelController

    var body: some View {
        VStack(spacing: 3) {
            Text(snapshot.title).font(.system(size: MenuBarPanelMetrics.smallFont)).foregroundStyle(Theme.menuPanelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .frame(height: 13).padding(.top, 7)
            if snapshot.contentHeight - MenuBarPanelMetrics.rowGap > MenuBarPanelMetrics.listMaxHeight {
                ScrollView {
                    LazyVStack(spacing: 2) { rows }
                }
                .modifier(MenuBarPanelScrollsToHighlight(level: level, navigation: controller.navigation))
                .frame(height: min(MenuBarPanelMetrics.listMaxHeight, snapshot.contentHeight - MenuBarPanelMetrics.rowGap))
            } else {
                VStack(spacing: 2) { rows }
            }
        }
        .padding(.bottom, 5).frame(width: MenuBarPanelMetrics.subWidth)
        .modifier(MenuBarPanelSurface(radius: MenuBarPanelMetrics.subRadius))
    }

    @ViewBuilder private var rows: some View {
        ForEach(snapshot.entries) { entry in
            switch entry.content {
            case let .heading(title):
                Text(title).font(.system(size: MenuBarPanelMetrics.smallFont)).foregroundStyle(Theme.menuPanelSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: MenuBarPanelMetrics.headingHeight - MenuBarPanelMetrics.rowGap)
            case let .option(option):
                MenuBarPanelNodeRow(snapshot: snapshot, option: option, level: level, controller: controller)
                    .padding(.horizontal, 6)
                    .id("option:" + option.id)   // 与键盘高亮 id 一致，供滚动定位
            case let .region(region):
                MenuBarPanelRegionRow(group: snapshot.group, region: region, level: level, controller: controller)
                    .padding(.horizontal, 6)
                    .id("region:" + region.id)
            }
        }
    }
}

private struct MenuBarPanelNodeRow: View {
    @Environment(AppState.self) private var state
    let snapshot: MenuBarPanelNodeSnapshot
    let option: GroupOption
    let level: Int
    let controller: MenuBarPanelController
    private var id: String { "option:" + option.id }

    var body: some View {
        let selected = snapshot.selected == option.name
        let item = MenuBarPanelItem(id: id, title: snapshot.title(for: option),
            enabled: snapshot.canSelect(option, busy: state.isBusy), action: .option(snapshot.group, option))
        Button { controller.activate(item, level: level) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.menuPanelAccent).opacity(selected ? 1 : 0).frame(width: 14)
                MenuBarPanelNodeName(title: item.title, option: option)
                Spacer(minLength: 0)
                if case let .node(node) = option { MenuBarPanelNodeDelay(nodeID: node.id) }
            }
            .padding(.horizontal, 8).frame(height: MenuBarPanelMetrics.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 只读不等于不可用：自动组选中的正常出口仍用主文字，只有动作被禁用。
        .disabled(!item.enabled)
        .background(controller.navigation.highlighted[level] == id ? Theme.menuPanelHover :
                    (selected ? Theme.menuPanelSelection : .clear), in: RoundedRectangle(cornerRadius: 6))
        .background(MenuBarPanelAnchor(id: id, level: level, controller: controller))
        .onHover { controller.hover(item, level: level, entered: $0) }
        .help(snapshot.title(for: option) + (snapshot.isReadOnly ? " · 自动选路，只读" : ""))
        .accessibilityLabel((selected ? "当前，" : "") + item.title)
    }
}

private struct MenuBarPanelNodeName: View {
    @Environment(AppState.self) private var state
    let title: String
    let option: GroupOption

    var body: some View {
        let timedOut: Bool = {
            guard case let .node(node) = option, case .some(.none) = state.delays[node.id] else { return false }
            return true
        }()
        Text(title).font(.system(size: MenuBarPanelMetrics.font)).lineLimit(1).truncationMode(.middle)
            .foregroundStyle(option.isAvailable && !timedOut ? Theme.menuPanelPrimary : Theme.menuPanelSecondary)
    }
}

struct MenuBarPanelNodeDelay: View {
    @Environment(AppState.self) private var state
    let nodeID: UUID

    var body: some View {
        Group {
            switch state.delays[nodeID] {
            case let .some(.some(delay)):
                Text("\(delay)ms").foregroundStyle(Theme.menuPanelDelayColor(delay))
            case .some(.none): Text("超时").foregroundStyle(Theme.menuPanelRed)
            case .none: EmptyView()
            }
        }
        .font(.system(size: MenuBarPanelMetrics.smallFont)).fixedSize()
    }
}

private struct MenuBarPanelRegionRow: View {
    let group: PolicyGroup
    let region: MenuBarPanelRegion
    let level: Int
    let controller: MenuBarPanelController

    var body: some View {
        let item = MenuBarPanelItem(id: "region:" + region.id, title: region.name,
                                    action: .region(group, region))
        Button { controller.activate(item, level: level) } label: {
            HStack(spacing: 8) {
                Text(region.name).font(.system(size: MenuBarPanelMetrics.font))
                Text("\(region.nodes.count) 个").font(.system(size: MenuBarPanelMetrics.smallFont)).foregroundStyle(Theme.menuPanelSecondary)
                Spacer(minLength: 0)
                MenuBarPanelRegionDelay(nodeIDs: region.nodes.map(\.id))
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(Theme.menuPanelSecondary)
            }
            .padding(.horizontal, 8).frame(height: MenuBarPanelMetrics.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(controller.navigation.highlighted[level] == item.id ? Theme.menuPanelHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .background(MenuBarPanelAnchor(id: item.id, level: level, controller: controller))
        .onHover { controller.hover(item, level: level, entered: $0) }
    }
}

private struct MenuBarPanelRegionDelay: View {
    @Environment(AppState.self) private var state
    let nodeIDs: [UUID]
    var body: some View {
        let minimum = nodeIDs.compactMap { id -> Int? in
            guard case let .some(.some(value)) = state.delays[id] else { return nil }
            return value
        }.min()
        Text(minimum.map { "\($0)ms 起" } ?? "—")
            .font(.system(size: MenuBarPanelMetrics.smallFont)).fixedSize()
            .foregroundStyle(minimum.map(Theme.menuPanelDelayColor) ?? Theme.menuPanelSecondary)
    }
}

struct MenuBarPanelListView: View {
    let title: String
    let items: [MenuBarPanelItem]
    let level: Int
    let controller: MenuBarPanelController

    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: MenuBarPanelMetrics.smallFont)).foregroundStyle(Theme.menuPanelSecondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
                .frame(height: 13).padding(.top, 7)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in MenuBarPanelRow(item: item, level: level, controller: controller) }
                }
                .padding(.horizontal, 6)
            }
            .modifier(MenuBarPanelScrollsToHighlight(level: level, navigation: controller.navigation))
            .frame(height: min(MenuBarPanelMetrics.listMaxHeight, CGFloat(items.count) * MenuBarPanelMetrics.rowStep - MenuBarPanelMetrics.rowGap))
        }
        .padding(.bottom, 5).frame(width: MenuBarPanelMetrics.subWidth).modifier(MenuBarPanelSurface(radius: MenuBarPanelMetrics.subRadius))
    }
}

/// 键盘移动高亮时把高亮行滚进可视区。长列表是 LazyVStack，没实例化的行没有 AppKit 锚点，
/// `scrollToVisible` 够不着；这里按行 id 由 ScrollViewReader 滚（2026-11-09 审计：几百个节点时 ↓ 到第 10 行后高亮跑出可视区）。
private struct MenuBarPanelScrollsToHighlight: ViewModifier {
    let level: Int
    let navigation: MenuBarPanelNavigation

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: navigation.highlighted[level]) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }
}
