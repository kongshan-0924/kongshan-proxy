import KongshanCore
import SwiftUI

/// 消息中心：集中展示错误与警告。工具栏通知按钮只显示最新一条，完整列表在这里。
struct MessagesView: View {
    @Environment(AppState.self) private var state
    @State private var tab: Tab = .warnings
    /// 运行事件里绝大多数是 info（启动/停止/换网）。排查时真正要看的是 warning 与 error，
    /// 200 条里往往只有几条。与内核日志页的「只看问题」同一个用意。
    @AppStorage("messages.events.problemsOnly") private var eventProblemsOnly = false

    private enum Tab: String, CaseIterable {
        case warnings = "警告"
        case events = "运行事件"
    }

    var body: some View {
        Group {
            if tab == .warnings { warningList } else { eventList }
        }
        .navigationTitle("消息")
        .navigationSubtitle(subtitle)
        .toolbar {
            // 分区切换放工具栏正中：访达的视图切换器就在这个位置。
            ToolbarItem(placement: .principal) {
                Picker("消息类型", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.dismissError()
                    state.clearWarnings()
                    state.clearRuntimeEvents()
                } label: {
                    Label("全部清除", systemImage: "trash")
                }
                .disabled(state.errorMessage == nil && state.warnings.isEmpty && state.runtimeEvents.isEmpty)
                .help("清空消息页；告警与指标的存档不受影响")
            }
        }
        // 让用户知道清除不会毁掉证据——否则「全部清除」看起来就是不可逆的销毁。
        // 放在底栏：邮件/访达的状态信息都在窗口底部那一条。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "archivebox")
                    Text("警告与错误另存于 \(state.diagnosticsArchivePath)；"
                         + "运行指标每分钟记一行到 \(state.metricsArchivePath)。两者都不受「全部清除」影响")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
    }

    private var subtitle: String {
        switch tab {
        case .warnings:
            let count = (state.errorMessage != nil ? 1 : 0) + state.warnings.count
            return count == 0 ? "没有未处理的消息" : "\(count) 条"
        case .events:
            return eventProblemsOnly
                ? "\(visibleEvents.count) / \(state.runtimeEvents.count) 条"
                : "\(state.runtimeEvents.count) 条"
        }
    }

    private var warningList: some View {
        List {
            if let error = state.errorMessage {
                messageRow(text: error, symbol: "exclamationmark.octagon.fill", tint: .red)
            }
            ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                messageRow(text: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
        }
        .listStyle(.inset)
        .overlay {
            if state.errorMessage == nil && state.warnings.isEmpty {
                ContentUnavailableView(
                    "暂无消息",
                    systemImage: "checkmark.circle",
                    description: Text("代理运行中出现错误或警告时会显示在这里。")
                )
            }
        }
    }

    /// 一次算好再交给列表：`ForEach` 在 body 里过滤等于每次重绘都重算一遍。
    private var visibleEvents: [RuntimeEvent] {
        eventProblemsOnly ? state.runtimeEvents.filter { $0.level != .info } : state.runtimeEvents
    }

    private var eventList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("只看问题", isOn: $eventProblemsOnly)
                    .toggleStyle(.checkbox)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            List {
                ForEach(visibleEvents.reversed()) { event in
                    eventRow(event)
                }
            }
            .listStyle(.inset)
            .overlay {
                if visibleEvents.isEmpty {
                    ContentUnavailableView(
                        eventProblemsOnly ? "没有问题事件" : "暂无运行事件",
                        systemImage: eventProblemsOnly ? "checkmark.circle" : "clock.arrow.circlepath",
                        description: eventProblemsOnly
                            ? Text("当前 \(state.runtimeEvents.count) 条记录里没有警告或错误。")
                            : nil
                    )
                }
            }
        }
    }

    private func eventRow(_ event: RuntimeEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: eventSymbol(event.level))
                .foregroundStyle(eventTint(event.level))
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.body.weight(.medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                    if event.previousPID != nil || event.currentPID != nil {
                        Text("PID \(event.previousPID.map { String($0) } ?? "-") → \(event.currentPID.map { String($0) } ?? "-")")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
                .foregroundStyle(tint)
                .frame(width: 16)
                .padding(.top, 2)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}
