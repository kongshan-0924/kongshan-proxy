import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppState.self) private var state

    var body: some View {
        Button(state.isOn ? "关闭系统代理" : "开启系统代理") {
            Task {
                if state.isOn {
                    await state.stop()
                } else {
                    await state.startSystemProxy()
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

        Text("模式：系统代理")

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
}
