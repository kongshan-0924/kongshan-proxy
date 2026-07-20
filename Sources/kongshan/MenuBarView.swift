import AppKit
import KongshanCore
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var state

    var body: some View {
        Button(toggleTitle) {
            Task {
                if state.activeMode != nil {
                    await state.stop()
                } else {
                    await state.startPreferredProxy()
                }
            }
        }
        .disabled(state.isBusy || !state.isReady)

        Text(state.statusText)

        if !state.nodes.isEmpty {
            Menu("当前节点：\(state.selectedNode?.name ?? "未选择")") {
                ForEach(state.nodes) { node in
                    Button {
                        Task { await state.select(node) }
                    } label: {
                        if state.selectedNodeID == node.id {
                            Label(node.name, systemImage: "checkmark")
                        } else {
                            Text(node.name)
                        }
                    }
                }
            }
            .disabled(state.isBusy)
        }

        Text(state.activeMode.map { "当前模式：\(modeTitle($0))" } ?? "首选模式：\(modeTitle(state.preferredMode))")
        Text("分流：\(state.routingSettings.customRules.filter(\.enabled).count) 条自定义规则 · 广告拦截\(state.routingSettings.blockAds ? "开" : "关")")

        Button("打开 kongshan") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var toggleTitle: String {
        if let activeMode = state.activeMode {
            return "关闭\(modeTitle(activeMode))"
        }
        return "开启\(modeTitle(state.preferredMode))"
    }

    private func modeTitle(_ mode: ProxyMode) -> String {
        mode == .tun ? "TUN" : "系统代理"
    }
}
