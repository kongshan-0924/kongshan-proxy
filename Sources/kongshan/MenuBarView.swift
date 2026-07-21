import AppKit
import KongshanCore
import SwiftUI

/// 菜单栏菜单。参考 Stash 的操作逻辑：顶部是仪表盘入口与测速全部，
/// 接管方式与出站模式分开，策略组各自有子菜单可单独指定节点并显示延迟。
/// 菜单是瞬时的，不建立任何 Clash WebSocket。
struct MenuBarView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Text(state.statusText)

        Button("打开仪表盘") { openMainWindow() }
            .keyboardShortcut("d")

        Divider()

        Menu("出站模式：\(state.outboundMode.displayName)") {
            Picker("出站模式", selection: outboundModeBinding) {
                ForEach(OutboundMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(state.isBusy || !state.isReady)

        // 两种接管方式互不排斥，各自一个勾选项
        Toggle(ProxyMode.systemProxy.displayName, isOn: modeBinding(.systemProxy))
            .keyboardShortcut("e")
            .disabled(state.isBusy || !state.isReady)

        Toggle(ProxyMode.tun.displayName, isOn: modeBinding(.tun))
            .keyboardShortcut("u")
            .disabled(state.isBusy || !state.isReady)

        // 内核可能因测速被拉起但没有接管，这里给一个明确的停止入口
        if state.isOn, state.activeModes.isEmpty {
            Button("停止内核") { Task { await state.stop() } }
                .disabled(state.isBusy)
        }

        Divider()

        // 每个可手动指定的策略独立选成员，右侧显示上次测速结果。
        // 名称截断，避免个别长名/长节点名把整个菜单撑得很宽。
        ForEach(state.displayPolicyGroups.filter { $0.kind == .selector }, id: \.name) { group in
            Menu("\(Self.clip(group.name, 14))：\(Self.clip(state.selectedMemberName(in: group.name) ?? "未选择", 16))") {
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
            Button(message.count > 48 ? String(message.prefix(48)) + "…" : message) {
                openMainWindow()
            }
        }

        Divider()

        Button("退出 kongshan") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// 托盘每个策略的子菜单最多列这么多项。菜单是「所有子菜单一次性全建出来」的，
    /// 上百节点×十几个组会建出几千个菜单项，既占内存又拖慢渲染；超出的去代理页选。
    private static let menuOptionLimit = 40

    @ViewBuilder
    private func optionMenuContent(for group: PolicyGroup) -> some View {
        let options = state.groupOptions(group)
        if options.isEmpty {
            Text("当前配置没有节点")
        } else {
            // 测速入口放在每个策略选节点列表的最上面，挑节点前先测。
            Button(state.isTestingAllDelays ? "正在测速…" : "测速全部") {
                Task { await state.testAllDelays() }
            }
            .disabled(state.testableNodes.isEmpty || state.isTestingAllDelays)
            Divider()
            // 选中项每组只算一次。之前每个选项都调 isSelected→selectedMemberName→groupOptions
            // 重建一遍全节点字典，几百节点×几十组就是 O(n²)，把 SwiftUI 菜单渲染顶到单核 100%。
            let selectedName = state.selectedMemberName(in: group.name)
            ForEach(options.prefix(Self.menuOptionLimit)) { option in
                optionButton(option, selected: option.name == selectedName, in: group.name)
            }
            if options.count > Self.menuOptionLimit {
                Divider()
                Button("在代理页选择全部（\(options.count) 个）…") { openMainWindow() }
            }
        }
    }

    private func optionButton(_ option: GroupOption, selected: Bool, in group: String) -> some View {
        Button {
            Task { await state.select(optionName: option.name, in: group) }
        } label: {
            let suffix: String = {
                if case let .node(node) = option {
                    switch state.delays[node.id] {
                    case let .some(.some(value)): return "   \(value) ms"
                    case .some(.none): return "   超时"
                    case .none: return ""
                    }
                }
                return ""
            }()
            if selected {
                Label("\(option.name)\(suffix)", systemImage: "checkmark")
            } else {
                Text("\(option.name)\(suffix)")
            }
        }
    }

    /// 截断过长文本，收窄菜单宽度。
    private static func clip(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max)) + "…" : text
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
