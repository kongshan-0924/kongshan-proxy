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
        VStack(spacing: 12) {
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
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - 状态与节点

    private var headerSection: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(state.statusTint)
                .frame(width: 9, height: 9)
                .shadow(color: state.statusTint.opacity(state.isOn ? 0.55 : 0), radius: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.statusText)
                    .font(.system(size: 13, weight: .semibold))
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
            Divider().frame(height: 30)
            rateColumn(symbol: "arrow.down", tint: .green, title: "下载", value: state.downloadRate)
        }
    }

    private func rateColumn(symbol: String, tint: Color, title: String, value: Int64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint.opacity(0.15))
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(Theme.rateOrDash(value))
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.25), value: value)
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
        VStack(spacing: 10) {
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
            .font(.system(size: 12, weight: .medium))
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

    private var groupSection: some View {
        VStack(spacing: 8) {
            ForEach(selectorGroups, id: \.name) { group in
                HStack(spacing: 8) {
                    Text(group.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    groupPicker(group)
                }
            }
        }
    }

    private func groupPicker(_ group: PolicyGroup) -> some View {
        let options = state.groupOptions(group)
        let selected = state.selectedMemberName(in: group.name, options: options)
        return Menu {
            ForEach(options.prefix(60)) { option in
                Button {
                    Task { await state.select(optionName: option.name, in: group.name) }
                } label: {
                    HStack {
                        if option.name == selected {
                            Image(systemName: "checkmark")
                        }
                        Text(optionTitle(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selected ?? "未选择")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.quaternary.opacity(0.7), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                Label("打开仪表盘", systemImage: "macwindow")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}
