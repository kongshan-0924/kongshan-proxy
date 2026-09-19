import KongshanCore
import SwiftUI

/// 测速地址。迁自 设置→网络·测速。
///
/// 用 sheet 而不是把 TextField 塞进菜单：菜单里放不下输入框，而任意 URL 的输入能力要保留。
struct SpeedTestURLSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("测试 URL", text: $draft, prompt: Text("https://www.gstatic.com/generate_204"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(save)
                } header: {
                    Text("测试地址")
                } footer: {
                    Text("URL 测速经当前代理请求这个地址，测的是真实链路。"
                         + "建议用返回 204 空响应的地址：省掉服务端生成页面的时间，各地区节点之间才可比。")
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || draft == state.testURLString)
            }
            .padding(14)
        }
        .frame(width: 460)
        .onAppear { draft = state.testURLString }
    }

    private func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        Task {
            await state.saveTestURL(value)
            dismiss()
        }
    }
}
