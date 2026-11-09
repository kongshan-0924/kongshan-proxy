import AppKit
import KongshanCore
import SwiftUI

// MARK: - 主菜单行模型
enum MenuBarPanelAction {
    case power, takeover(ProxyMode), modes, moreGroups, group(PolicyGroup)
    case outbound(OutboundMode), option(PolicyGroup, GroupOption)
    case region(PolicyGroup, MenuBarPanelRegion)
    case testDelays, dashboard, refresh, login, quit

    var expands: Bool {
        switch self {
        case .modes, .moreGroups, .group, .region: true
        default: false
        }
    }
}

struct MenuBarPanelItem: Identifiable {
    let id: String
    var title: String
    var symbol: String = ""
    var value: String = ""
    var toggle: Bool? = nil
    var enabled = true
    var checked = false
    let action: MenuBarPanelAction
}

@MainActor
struct MenuBarPanelModel {
    let state: AppState

    var groups: [PolicyGroup] {
        var groups = state.displayPolicyGroups
        if let primary = state.primaryGroupName, let index = groups.firstIndex(where: { $0.name == primary }) {
            groups.insert(groups.remove(at: index), at: 0)
        }
        return groups
    }

    var title: String {
        switch state.status {
        case .starting: "正在启动…"
        case .stopping: "正在关闭…"
        default: state.isOn ? "已开启" : "已关闭"
        }
    }
    var controlsOpacity: Double { state.isOn ? 1 : 0.4 }
    var sections: [[MenuBarPanelItem]] {
        let controls = [
            MenuBarPanelItem(id: "system", title: "系统代理", symbol: "globe", toggle: state.activeModes.contains(.systemProxy),
                             enabled: !state.isBusy, action: .takeover(.systemProxy)),
            MenuBarPanelItem(id: "tun", title: "TUN", symbol: "shield.lefthalf.filled", toggle: state.activeModes.contains(.tun),
                             enabled: !state.isBusy, action: .takeover(.tun)),
            MenuBarPanelItem(id: "modes", title: "模式", symbol: "slider.horizontal.3", value: state.outboundMode.displayName, action: .modes)
        ]
        var policies = groups.prefix(3).enumerated().map { index, group in
            groupItem(group, symbol: ["server.rack", "wand.and.stars", "cpu"][index])
        }
        if groups.count > 3 {
            policies.append(.init(id: "more", title: "更多策略组", symbol: "square.3.layers.3d",
                                  value: "\(groups.count - 3) 个", action: .moreGroups))
        }
        policies.append(.init(id: "test", title: "测试全部延迟", symbol: "speedometer", action: .testDelays))
        return [controls, policies, [
            .init(id: "dashboard", title: "打开主窗口", symbol: "arrow.up.forward.square", value: "⌘D", action: .dashboard),
            .init(id: "refresh", title: "刷新订阅", symbol: "arrow.clockwise", value: "⌘R", enabled: !state.isBusy, action: .refresh),
            .init(id: "login", title: "登录时启动", symbol: state.loginItemStatus == .enabled ? "checkmark" : "power",
                  enabled: state.loginItemStatus != .requiresApproval && state.loginItemStatus != .unsupported,
                  checked: state.loginItemStatus == .enabled, action: .login)
        ], [
            .init(id: "quit", title: "退出 kongshan", symbol: "rectangle.portrait.and.arrow.right", value: "⌘Q", action: .quit)
        ]]
    }

    func groupItem(_ group: PolicyGroup, symbol: String = "server.rack") -> MenuBarPanelItem {
        let options = state.groupOptions(group)
        return .init(id: "group:" + group.name, title: group.name, symbol: symbol,
                     // 右侧当前选择与原型一致不带国旗（地区码传空 = 只去国旗不加前缀）。
                     value: state.selectedMemberName(in: group.name, options: options)
                        .map { MenuBarPanelDirectory.nodeTitle($0, regionCode: "") } ?? "未选择", action: .group(group))
    }

    var height: CGFloat {
        // 顶边 + 状态头 + 每区一条带上下留白的分隔线 + 各行（行间 2）+ 底边。
        MenuBarPanelMetrics.padding * 2 + MenuBarPanelMetrics.headerHeight
            + CGFloat(sections.count) * (1 + MenuBarPanelMetrics.separatorInset * 2)
            + sections.reduce(0) { $0 + CGFloat($1.count) * MenuBarPanelMetrics.rowStep - MenuBarPanelMetrics.rowGap }
    }
}

// MARK: - 主面板

struct MenuBarPanelView: View {
    @Environment(AppState.self) private var state
    let controller: MenuBarPanelController

    var body: some View {
        let model = MenuBarPanelModel(state: state)
        VStack(spacing: 0) {
            MenuBarPanelHeader(controller: controller)
                .frame(height: MenuBarPanelMetrics.headerHeight)
            ForEach(Array(model.sections.enumerated()), id: \.offset) { index, section in
                Rectangle().fill(Theme.menuPanelSeparator).frame(height: 1)
                    .padding(.horizontal, 10).padding(.vertical, MenuBarPanelMetrics.separatorInset)
                VStack(spacing: 2) {
                    ForEach(section) { item in
                        if item.id == "test" {
                            MenuBarPanelTestRow(item: item, controller: controller)
                        } else {
                            MenuBarPanelRow(item: item, level: 0, controller: controller)
                        }
                    }
                }
                .opacity(index < 2 ? model.controlsOpacity : 1)
            }
        }
        .padding(MenuBarPanelMetrics.padding)
        .frame(width: MenuBarPanelMetrics.width)
        .modifier(MenuBarPanelSurface(radius: MenuBarPanelMetrics.mainRadius))
    }
}

private struct MenuBarPanelHeader: View {
    @Environment(AppState.self) private var state
    let controller: MenuBarPanelController

    var body: some View {
        Button { controller.perform(.power) } label: {
            HStack(spacing: 10) {
                Image(systemName: "power")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(state.isOn ? Theme.menuPanelAccent : Theme.menuPanelSecondary)
                    .frame(width: MenuBarPanelMetrics.tileSize, height: MenuBarPanelMetrics.tileSize)
                    .background(state.isOn ? Theme.menuPanelTileOn : Theme.menuPanelTileOff,
                                in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(MenuBarPanelModel(state: state).title).font(.system(size: MenuBarPanelMetrics.font, weight: .semibold))
                    MenuBarPanelCurrentNode()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                MenuBarPanelSwitch(isOn: state.isOn)
            }
            .padding(.horizontal, 4)
            .frame(height: MenuBarPanelMetrics.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(state.isBusy)
        .foregroundStyle(Theme.menuPanelPrimary)
        .background(controller.navigation.highlighted[0] == "power" ? Theme.menuPanelHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { entered in
            controller.hover(.init(id: "power", title: "总开关", enabled: !state.isBusy, action: .power),
                             level: 0, entered: entered)
        }
        .accessibilityLabel(MenuBarPanelModel(state: state).title + "，切换全部接管")
    }
}

private struct MenuBarPanelCurrentNode: View {
    @Environment(AppState.self) private var state
    var body: some View {
        let group = MenuBarPanelModel(state: state).groups.first
        let options = group.map(state.groupOptions) ?? []
        let selected = group.flatMap { state.selectedMemberName(in: $0.name, options: options) }
        let node = options.first { $0.name == selected }
        Text(node.map { option in
            if case let .node(value) = option {
                return MenuBarPanelDirectory.nodeTitle(value.name, regionCode: state.nodeCatalog.metadataByNodeID[value.id]?.regionCode ?? "")
            }
            return option.name
        } ?? "未选择节点")
        .font(.system(size: MenuBarPanelMetrics.smallFont)).foregroundStyle(Theme.menuPanelSecondary)
        .lineLimit(1).truncationMode(.middle)
    }
}

// MARK: - 共用行、开关与表面
struct MenuBarPanelSwitch: View {
    let isOn: Bool
    var body: some View {
        Capsule(style: .circular).fill(isOn ? Theme.menuPanelAccent : Theme.menuPanelSwitchOff)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(Theme.menuPanelKnob).frame(width: MenuBarPanelMetrics.knob, height: MenuBarPanelMetrics.knob).padding(2)
            }
            .frame(width: MenuBarPanelMetrics.switchSize.width, height: MenuBarPanelMetrics.switchSize.height)
            .accessibilityHidden(true)
    }
}

struct MenuBarPanelSurface: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View {
        content
            .foregroundStyle(Theme.menuPanelPrimary)
            // 底板、圆角裁切与阴影由面板窗口的系统材质负责（MenuBarPanelController.nativeSurface），这里只画细描边。
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.menuPanelStroke, lineWidth: 0.5))
    }
}

struct MenuBarPanelRow: View {
    let item: MenuBarPanelItem
    let level: Int
    let controller: MenuBarPanelController

    var body: some View {
        Button { controller.activate(item, level: level) } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol)
                    .font(.system(size: MenuBarPanelMetrics.font))
                    .foregroundStyle(item.checked ? Theme.menuPanelAccent : Theme.menuPanelSecondary)
                    .frame(width: MenuBarPanelMetrics.iconColumn).accessibilityHidden(true)
                Text(item.title).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 0)
                if let toggle = item.toggle {
                    MenuBarPanelSwitch(isOn: toggle)
                } else {
                    if !item.value.isEmpty {
                        Text(item.value).foregroundStyle(Theme.menuPanelSecondary)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: item.action.expands ? MenuBarPanelMetrics.valueMaxWidth : nil, alignment: .trailing)
                    }
                    if item.action.expands {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.menuPanelSecondary)
                    }
                }
            }
            .font(.system(size: MenuBarPanelMetrics.font))
            .padding(.horizontal, 9).frame(height: MenuBarPanelMetrics.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!item.enabled)
        .background(controller.navigation.highlighted[level] == item.id ? Theme.menuPanelHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .background(MenuBarPanelAnchor(id: item.id, level: level, controller: controller))
        .onHover { controller.hover(item, level: level, entered: $0) }
        .accessibilityLabel(item.title + (item.toggle.map { $0 ? "，开启" : "，关闭" } ?? ""))
        .accessibilityValue(item.value)
    }
}

struct MenuBarPanelTestRow: View {
    @Environment(AppState.self) private var state
    let item: MenuBarPanelItem
    let controller: MenuBarPanelController

    static func title(testing: Bool, completed: Int, total: Int) -> String {
        testing ? "取消测试（\(completed)/\(total)）" : "测试全部延迟"
    }

    var body: some View {
        var row = item
        row.title = Self.title(testing: state.isTestingAllDelays,
                               completed: state.speedTestProgress.completed, total: state.speedTestProgress.total)
        return MenuBarPanelRow(item: row, level: 0, controller: controller)
    }
}

// MARK: - AppKit 行定位

struct MenuBarPanelAnchor: NSViewRepresentable {
    let id: String
    let level: Int
    let controller: MenuBarPanelController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        controller.register(view, id: id, level: level)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        controller.register(view, id: id, level: level)
    }
}
