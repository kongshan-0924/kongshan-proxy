import KongshanCore
import SwiftUI

/// 菜单栏左键弹出的迷你仪表盘。
///
/// 与主窗口共用 AppState 的常驻推流（startMenuBarMonitoring 一直挂着），
/// 面板本身不启动任何额外采样；弹出不重建 AppKit 菜单，速率只更新数字文本。
struct MenuBarPopoverView: View {
    @Environment(AppState.self) private var state
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerSection
            rateSection
            Divider()
            modeSection
            if !selectorGroups.isEmpty {
                Divider()
                groupSection
            }
            Divider()
            footerSection
        }
        .padding(14)
        .frame(width: 290)
    }

    // MARK: - 状态与节点

    private var headerSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.statusTint)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.statusText)
                    .font(.headline)
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
            if let node = state.selectedNode, let delay = state.delays[node.id] {
                DelayLabel(milliseconds: delay)
            }
        }
    }

    // MARK: - 实时速率

    private var rateSection: some View {
        HStack(spacing: 0) {
            rateColumn(symbol: "arrow.up", tint: .blue, title: "上传", value: state.uploadRate)
            Divider().frame(height: 28)
            rateColumn(symbol: "arrow.down", tint: .green, title: "下载", value: state.downloadRate)
        }
    }

    private func rateColumn(symbol: String, tint: Color, title: String, value: Int64) -> some View {
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
    }

    // MARK: - 模式与开关

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("出站模式", selection: outboundModeBinding) {
                ForEach(OutboundMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .disabled(state.isBusy || !state.isReady)

            HStack(spacing: 10) {
                modeToggle(title: ProxyMode.systemProxy.displayName, mode: .systemProxy)
                modeToggle(title: ProxyMode.tun.displayName, mode: .tun)
            }
        }
    }

    private var outboundModeBinding: Binding<OutboundMode> {
        Binding(
            get: { state.outboundMode },
            set: { mode in Task { await state.setOutboundMode(mode) } }
        )
    }

    private func modeToggle(title: String, mode: ProxyMode) -> some View {
        Toggle(title, isOn: modeBinding(mode))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(state.isBusy || !state.isReady)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modeBinding(_ mode: ProxyMode) -> Binding<Bool> {
        Binding(
            get: { state.activeModes.contains(mode) },
            set: { enabled in Task { await state.setMode(mode, enabled: enabled) } }
        )
    }

    // MARK: - 策略组

    private var selectorGroups: [PolicyGroup] {
        state.displayPolicyGroups.filter { $0.kind == .selector }
    }

    /// 每个策略一行系统弹出按钮（`Picker(.menu)`）：标签在左、当前选择在右，
    /// 与系统设置里的下拉项同形，不再自绘带描边的菜单标签。
    private var groupSection: some View {
        // 两列网格让所有弹出按钮左沿对齐——系统设置里标签列 + 控件列就是这个形状。
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            ForEach(selectorGroups, id: \.name) { group in
                GridRow {
                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .gridColumnAlignment(.leading)
                    groupPicker(group)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func groupPicker(_ group: PolicyGroup) -> some View {
        let options = state.groupOptions(group)
        let selected = state.selectedMemberName(in: group.name, options: options) ?? ""
        let binding = Binding<String>(
            get: { selected },
            set: { name in
                guard !name.isEmpty, name != selected else { return }
                Task { await state.select(optionName: name, in: group.name) }
            }
        )
        return Picker(selection: binding) {
            if selected.isEmpty { Text("未选择").tag("") }
            ForEach(options.prefix(60)) { option in
                Text(optionTitle(option)).tag(option.name)
            }
        } label: {
            Text(group.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(state.isBusy || options.isEmpty)
    }

    private func optionTitle(_ option: GroupOption) -> String {
        guard case let .node(node) = option else { return option.name }
        switch state.delays[node.id] {
        case let .some(.some(value)): return "\(option.name) · \(value) ms"
        case .some(.none): return "\(option.name) · 超时"
        case .none: return option.name
        }
    }

    // MARK: - 底部

    private var footerSection: some View {
        HStack(spacing: 10) {
            Button {
                openMainWindow()
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            .buttonStyle(.link)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
