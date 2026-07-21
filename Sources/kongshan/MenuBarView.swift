import AppKit
import KongshanCore
import SwiftUI

/// 菜单栏菜单。短标题 + 截断节点名，避免状态栏下拉过宽。
struct MenuBarView: View {
    @Environment(AppState.self) private var state

    private static let titleMemberLimit = 18
    private static let optionNameLimit = 36

    var body: some View {
        Text(compactStatusText)

        Button("打开仪表盘") { openMainWindow() }
            .keyboardShortcut("d")

        Button(state.isTestingAllDelays ? "正在测速…" : "测速全部") {
            Task { await state.testAllDelays() }
        }
        .keyboardShortcut("t")
        .disabled(state.testableNodes.isEmpty || state.isBusy || state.isTestingAllDelays)

        Divider()

        Menu("出站模式") {
            Picker("出站模式", selection: outboundModeBinding) {
                ForEach(OutboundMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(state.isBusy || !state.isReady)

        Toggle("系统代理", isOn: modeBinding(.systemProxy))
            .keyboardShortcut("e")
            .disabled(state.isBusy || !state.isReady)

        Toggle("TUN", isOn: modeBinding(.tun))
            .keyboardShortcut("u")
            .disabled(state.isBusy || !state.isReady)

        if state.isOn, state.activeModes.isEmpty {
            Button("停止内核") { Task { await state.stop() } }
                .disabled(state.isBusy)
        }

        Divider()

        // 仅 selector；标题截断选中成员，避免 UUID/长节点名撑宽整栏
        ForEach(state.displayPolicyGroups.filter { $0.kind == .selector }) { group in
            Menu(menuTitle(for: group)) {
                optionMenuContent(for: group)
            }
            .disabled(state.isBusy || state.testableNodes.isEmpty)
        }

        Divider()

        Toggle("登录时启动", isOn: launchAtLoginBinding)
            .disabled(
                !state.isReady
                    || state.loginItemStatus == .requiresApproval
                    || state.loginItemStatus == .notFound
            )

        Button("刷新订阅") {
            Task { await state.refreshSubscriptions() }
        }
        .keyboardShortcut("r")
        .disabled(state.subscriptions.isEmpty || state.isBusy)

        if let message = state.errorMessage ?? state.warnings.last {
            Divider()
            Button(Self.ellipsis(message, limit: 40)) {
                openMainWindow()
            }
        }

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var compactStatusText: String {
        switch state.status {
        case .off:
            return "已关闭"
        case .starting:
            return "启动中…"
        case .stopping:
            return "关闭中…"
        case .on where state.activeModes.isEmpty:
            return "内核就绪"
        case .on:
            let modes = [ProxyMode.systemProxy, .tun]
                .filter(state.activeModes.contains)
                .map { $0 == .tun ? "TUN" : "系统代理" }
            return modes.isEmpty ? "已开启" : modes.joined(separator: "+")
        case .failed:
            return "失败"
        }
    }

    private func menuTitle(for group: PolicyGroup) -> String {
        let member = state.selectedMemberName(in: group.name).map {
            Self.ellipsis($0, limit: Self.titleMemberLimit)
        } ?? "未选择"
        let groupLabel = Self.ellipsis(group.name, limit: 12)
        return "\(groupLabel)：\(member)"
    }

    @ViewBuilder
    private func optionMenuContent(for group: PolicyGroup) -> some View {
        let options = state.groupOptions(group)
        if options.isEmpty {
            Text("当前配置没有节点")
        } else {
            ForEach(options) { option in
                optionButton(option, in: group.name)
            }
        }
    }

    private func optionButton(_ option: GroupOption, in group: String) -> some View {
        Button {
            Task { await state.select(optionName: option.name, in: group) }
        } label: {
            let label = Self.ellipsis(option.name, limit: Self.optionNameLimit)
            let suffix: String = {
                if case let .node(node) = option {
                    switch state.delays[node.id] {
                    case let .some(.some(value)): return "  \(value)ms"
                    case .some(.none): return "  超时"
                    case .none: return ""
                    }
                }
                return ""
            }()
            if state.isSelected(option, in: group) {
                Label("\(label)\(suffix)", systemImage: "checkmark")
            } else {
                Text("\(label)\(suffix)")
            }
        }
    }

    private static func ellipsis(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 1 else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private func openMainWindow() {
        (NSApp.delegate as? KongshanAppDelegate)?.showMainWindow()
    }

    private var outboundModeBinding: Binding<OutboundMode> {
        Binding(
            get: { state.outboundMode },
            set: { mode in Task { await state.setOutboundMode(mode) } }
        )
    }

    private func modeBinding(_ mode: ProxyMode) -> Binding<Bool> {
        Binding(
            get: { state.activeModes.contains(mode) },
            set: { enabled in Task { await state.setMode(mode, enabled: enabled) } }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.loginItemStatus == .enabled },
            set: { enabled in Task { await state.setLaunchAtLoginEnabled(enabled) } }
        )
    }
}
