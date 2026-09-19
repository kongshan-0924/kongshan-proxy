import KongshanCore
import SwiftUI

/// 订阅自动更新。迁自 设置→资源·订阅自动更新。
///
/// 它讲的是「订阅什么时候刷新」，而「已用 / 总量 / 到期」就印在配置页每一行的副标题上——
/// 同一件事的两半原先隔着两个页面。配置页底栏常驻一行状态，点「更改…」弹出这里。
struct SubscriptionScheduleSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SubscriptionUpdateSettings.defaults

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    Toggle("启用自动更新", isOn: $draft.enabled)
                    Stepper(
                        "更新间隔：\(draft.intervalHours) 小时",
                        value: $draft.intervalHours,
                        in: 1...168
                    )
                    .disabled(!draft.enabled)
                    LabeledContent(
                        "下次更新",
                        value: state.nextSubscriptionUpdateAt?.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ) ?? "未安排"
                    )
                } footer: {
                    Text("按最近到期的订阅安排一次更新，完成后重新计算时间，不会持续轮询。"
                         + "失败时保留原节点和缓存，并尝试发送本地通知。")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("放弃修改") { draft = state.subscriptionUpdateSettings }
                    .disabled(draft == state.subscriptionUpdateSettings)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    Task {
                        await state.setSubscriptionUpdateSettings(draft)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || !state.isReady || draft == state.subscriptionUpdateSettings)
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear { draft = state.subscriptionUpdateSettings }
    }
}
