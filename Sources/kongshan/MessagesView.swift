import KongshanCore
import SwiftUI

/// 消息中心：集中展示错误与警告。顶部提醒条只显示最新一条，完整列表在这里。
struct MessagesView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "消息", subtitle: "应用运行中的错误与警告") {
                Button("全部清除") {
                    state.dismissError()
                    state.clearWarnings()
                }
                .disabled(state.errorMessage == nil && state.warnings.isEmpty)
            }
            Divider()
            list
        }
        .pageBackground()
        .navigationTitle("消息")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let error = state.errorMessage {
                    messageRow(text: error, symbol: "exclamationmark.octagon.fill", tint: .red)
                    Divider().opacity(0.4)
                }
                ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                    messageRow(text: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    Divider().opacity(0.4)
                }
                if state.errorMessage == nil && state.warnings.isEmpty {
                    ContentUnavailableView(
                        "暂无消息",
                        systemImage: "checkmark.circle",
                        description: Text("代理运行中出现错误或警告时会显示在这里。")
                    )
                    .padding(.top, 80)
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func messageRow(text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .padding(.top, 2)
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }
}
