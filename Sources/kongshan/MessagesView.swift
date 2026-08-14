import KongshanCore
import SwiftUI

/// 消息中心：集中展示错误与警告。顶部提醒条只显示最新一条，完整列表在这里。
struct MessagesView: View {
    @Environment(AppState.self) private var state
    @State private var tab: Tab = .warnings

    private enum Tab: String, CaseIterable {
        case warnings = "警告"
        case events = "运行事件"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "消息", subtitle: "应用运行中的错误与警告") {
                Button("全部清除") {
                    state.dismissError()
                    state.clearWarnings()
                    state.clearRuntimeEvents()
                }
                .disabled(state.errorMessage == nil && state.warnings.isEmpty && state.runtimeEvents.isEmpty)
            }
            Picker("消息类型", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.vertical, 10)
            Divider()
            if tab == .warnings { warningList } else { eventList }
        }
        .pageBackground()
        .navigationTitle("消息")
    }

    private var warningList: some View {
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
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(state.runtimeEvents.reversed()) { event in
                    eventRow(event)
                    Divider().opacity(0.4)
                }
                if state.runtimeEvents.isEmpty {
                    ContentUnavailableView("暂无运行事件", systemImage: "clock.arrow.circlepath")
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    private func eventRow(_ event: RuntimeEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: eventSymbol(event.level))
                .font(.system(size: 13))
                .foregroundStyle(eventTint(event.level))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title).font(.system(size: 13, weight: .medium))
                if let detail = event.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                    if event.previousPID != nil || event.currentPID != nil {
                        Text("PID \(event.previousPID.map { String($0) } ?? "-") → \(event.currentPID.map { String($0) } ?? "-")")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func eventSymbol(_ level: RuntimeEvent.Level) -> String {
        switch level {
        case .info: "clock.arrow.circlepath"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    private func eventTint(_ level: RuntimeEvent.Level) -> Color {
        switch level {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
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
