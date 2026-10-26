import KongshanCore
import SwiftUI

/// 菜单栏左键弹出的迷你仪表盘。
///
/// 与主窗口共用 AppState 的常驻推流（startMenuBarMonitoring 一直挂着），
/// 面板本身不启动任何额外采样；弹出不重建 AppKit 菜单，速率只更新数字文本。
/// 外观与主窗口同一套：浅灰画布 + 白卡（`CardGroupBoxStyle`）+ 胶囊按钮与胶囊选择器。
struct MenuBarPopoverView: View {
    @Environment(AppState.self) private var state
    let openMainWindow: () -> Void
    /// 点策略组那一行：由 `MenuBarController` 在鼠标处弹出原生菜单，选项与右键菜单同一份、打开时才构建。
    ///
    /// 不在面板里放 `Picker`：真实订阅十几个组、每组四百多个节点，每个 `Picker` 都要预先建好全部菜单项，
    /// 弹出面板和测速刷新延迟时整批重建；截断到前 N 个又会让排在后面的已选节点对不上标签。
    let showGroupMenu: (String) -> Void

    static let width: CGFloat = 300
    /// 组多时只露这么多行，其余在卡片里滚动，面板不至于顶出屏幕。
    private static let visibleGroupRows = 7
    private static let groupRowHeight: CGFloat = 28

    var body: some View {
        VStack(spacing: 10) {
            statusCard
            controlCard
            if !selectorGroups.isEmpty {
                groupCard
            }
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .background(Theme.canvasBackground)
        .groupBoxStyle(CardGroupBoxStyle())
        .buttonStyle(.pill)
    }

    // MARK: - 状态与速率

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(state.statusTint)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.statusText)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(state.selectedNode?.name ?? "未选择节点")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let node = state.selectedNode {
                                ProtocolTag(value: node.protocolType)
                            }
                        }
                    }
                    Spacer(minLength: 8)
                    if state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else if let node = state.selectedNode, let delay = state.delays[node.id] {
                        DelayLabel(milliseconds: delay)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    MenuBarRateColumn(symbol: "arrow.up", tint: Theme.uploadTint, title: "上传", value: state.uploadRate)
                    Divider().frame(height: 26)
                    MenuBarRateColumn(symbol: "arrow.down", tint: Theme.downloadTint, title: "下载", value: state.downloadRate)
                }
            }
        }
    }

    // MARK: - 出站模式与接管

    private var controlCard: some View {
        GroupBox {
            VStack(spacing: 10) {
                CapsuleSegmentedPicker(options: OutboundMode.allCases, selection: state.outboundModeBinding) { $0.displayName }
                    .disabled(state.isBusy || !state.isReady)
                HStack(spacing: 0) {
                    modeToggle(.systemProxy)
                    Divider().frame(height: 20).padding(.horizontal, 10)
                    modeToggle(.tun)
                }
            }
        }
    }

    /// 标签在左、开关在右，两列等宽：与主窗口表单行同一排法，两个开关上下对齐。
    private func modeToggle(_ mode: ProxyMode) -> some View {
        HStack {
            Text(mode.displayName)
                .font(.callout)
            Spacer(minLength: 6)
            Toggle(mode.displayName, isOn: state.takeoverModeBinding(mode))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .disabled(state.isBusy || !state.isReady)
    }

    // MARK: - 策略组

    private var selectorGroups: [PolicyGroup] {
        state.displayPolicyGroups.filter { $0.kind == .selector }
    }

    private var groupCard: some View {
        GroupBox {
            let groups = selectorGroups
            let rows = VStack(spacing: 0) {
                ForEach(groups, id: \.name) { group in
                    MenuBarGroupRow(group: group, height: Self.groupRowHeight) {
                        showGroupMenu(group.name)
                    }
                }
            }
            if groups.count > Self.visibleGroupRows {
                ScrollView {
                    rows
                }
                // 不留滚动条槽：常显滚动条（鼠标用户）会挤掉节点名。露出的半行已经提示下面还有。
                .scrollIndicators(.never)
                // 露出半行，提示下面还有。
                .frame(height: Self.groupRowHeight * (CGFloat(Self.visibleGroupRows) + 0.5))
            } else {
                rows
            }
        } label: {
            HStack {
                Text("策略组")
                Spacer()
                speedTestButton
                    .font(.callout)
            }
        }
    }

    @ViewBuilder
    private var speedTestButton: some View {
        if state.isTestingAllDelays {
            Button("取消 \(state.speedTestProgress.label)") { state.cancelDelayTests() }
                .monospacedDigit()
        } else {
            Button("测速") { state.startAllDelayTests() }
                .disabled(state.testableNodes.isEmpty)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            Button {
                openMainWindow()
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
        }
        .padding(.horizontal, 2)
    }
}

/// 速率一列。单独成视图：每秒变的数字只让这一小块重算，不带上整张面板。
private struct MenuBarRateColumn: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: Int64

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // 高频数值不做动画：弹簧插值会让本视图在每次速率采样后按刷新率持续重绘
                //（DashboardView 有完整说明与真机代价）。
                Text(Theme.rateOrDash(value))
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
    }
}

/// 策略组一行：组名 · 当前选择 · 延迟，整行可点，悬停有底色。
private struct MenuBarGroupRow: View {
    @Environment(AppState.self) private var state
    let group: PolicyGroup
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let options = state.groupOptions(group)
        let selected = state.selectedMemberName(in: group.name, options: options)
        let node: ProxyNode? = options.lazy.compactMap { option -> ProxyNode? in
            guard case let .node(node) = option, node.name == selected else { return nil }
            return node
        }.first
        Button(action: action) {
            HStack(spacing: 8) {
                Text(group.name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 88, alignment: .leading)
                Text(selected ?? "未选择")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let node, let delay = state.delays[node.id] {
                    DelayLabel(milliseconds: delay)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .frame(height: height)
            .contentShape(Rectangle())
            .background(
                hovering ? Theme.canvasBackground : .clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy || options.isEmpty)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(group.name)：\(selected ?? "未选择")")
        .accessibilityHint("选择节点")
    }
}
