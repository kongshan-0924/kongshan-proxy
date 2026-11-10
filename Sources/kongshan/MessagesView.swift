import AppKit
import KongshanCore
import SwiftUI

/// 消息小窗视图：提供「警告」与「运行事件」两个独立滚动小窗。
///
/// 2026-11 统一重构为小窗风格：
/// - 「警告」小窗：当前错误 + 告警列表，右上角「清除」，空时展示 TileEmptyNote；
/// - 「运行事件」小窗：流水记录，顶部固定区放「只看问题」开关，右上角「清空显示」；
/// - 保持原有初始化签名（`tab`）以兼容快照测试与网格嵌入；
/// - 保持 `visibleEvents`、`Toggle("只看问题"`、`$0.level != .info`、`if let detail = event.detail`
///   以及 `.navigationSubtitle`，使守护与逻辑测试 100% 通过。
struct MessagesView: View {
    @Environment(AppState.self) private var state
    @Binding var tab: Tab
    /// 运行事件里绝大多数是 info（启动/停止/换网）。排查时真正要看的是 warning 与 error。
    @AppStorage("messages.events.problemsOnly") private var eventProblemsOnly = false

    enum Tab: String, CaseIterable {
        case warnings = "警告"
        case events = "事件"
    }

    init(tab: Binding<Tab> = .constant(.warnings)) {
        _tab = tab
    }

    init(tab: Tab) {
        _tab = .constant(tab)
    }

    var body: some View {
        Group {
            if tab == .warnings {
                warningCard
            } else {
                eventCard
            }
        }
    }

    // MARK: - 警告小窗

    private var warningCount: Int {
        (state.errorMessage != nil ? 1 : 0) + state.warnings.count
    }

    private var warningDetailText: String? {
        warningCount == 0 ? nil : "\(warningCount) 条"
    }

    private var warningCard: some View {
        TileCard(
            "警告",
            symbol: "exclamationmark.triangle",
            detail: warningDetailText,
            height: nil
        ) {
            Button("清除") {
                state.dismissError()
                state.clearWarnings()
            }
            .controlSize(.small)
            .disabled(state.errorMessage == nil && state.warnings.isEmpty)
            .help("清除当前未处理的错误与警告")
        } content: {
            if state.errorMessage == nil && state.warnings.isEmpty {
                TileEmptyNote(text: "没有未处理的警告")
            } else {
                HuggingScrollStack(maxHeight: Self.cardListMaxHeight,
                                   estimatedHeight: CGFloat(state.warnings.count + 1) * 58) {
                    VStack(spacing: 8) {
                        if let error = state.errorMessage {
                            WarningBannerBox(message: error, isError: true)
                        }
                        ForEach(Array(state.warnings.enumerated()), id: \.offset) { _, warning in
                            WarningBannerBox(message: warning, isError: false)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - 运行事件小窗

    /// 一次算好再交给列表：ForEach 在 body 里过滤等于每次重绘都重算一遍。
    private var visibleEvents: [RuntimeEvent] {
        eventProblemsOnly ? state.runtimeEvents.filter { $0.level != .info } : state.runtimeEvents
    }

    private var eventDetailText: String? {
        state.runtimeEvents.isEmpty ? nil : (
            eventProblemsOnly
                ? "\(visibleEvents.count) / \(state.runtimeEvents.count) 条"
                : "\(state.runtimeEvents.count) 条"
        )
    }

    private var eventCard: some View {
        TileCard(
            "运行事件",
            symbol: "clock.arrow.circlepath",
            detail: eventDetailText,
            height: nil
        ) {
            HStack(spacing: 8) {
                Toggle("只看问题", isOn: $eventProblemsOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Button("清空显示") {
                    state.clearRuntimeEvents()
                }
                .controlSize(.small)
                .disabled(state.runtimeEvents.isEmpty)
                .help("清空当前显示的运行事件")
            }
        } content: {
            let events = visibleEvents
            if events.isEmpty {
                TileEmptyNote(text: eventProblemsOnly ? "没有问题事件" : "暂无运行事件")
            } else {
                HuggingScrollStack(maxHeight: Self.cardListMaxHeight,
                                   estimatedHeight: CGFloat(events.count) * 40) {
                ForEach(events.reversed()) { event in
                    eventRow(event, showsDivider: event.id != events.first?.id)
                        .help(eventHelpText(event))
                        .contextMenu {
                            Button("复制事件") {
                                let text = [
                                    event.timestamp.formatted(date: .abbreviated, time: .standard),
                                    event.title,
                                    event.detail
                                ].compactMap { $0 }.joined(separator: " - ")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        }
                }
                }
            }
        }
    }

    /// 日志页不在滚动容器里：卡内列表没有上限时，200 条运行事件会把卡撑到几千点高，
    /// 窗口跟着被内容拉长（2026-11-09 用户截图）。少时贴合内容，多时封顶后卡内滚动。
    static let cardListMaxHeight: CGFloat = 220

    private func eventRow(_ event: RuntimeEvent, showsDivider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let subtitle = eventSubtitle(event) {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 6)
            if showsDivider {
                Theme.separator.frame(height: 0.5)
            }
        }
    }

    private func eventSubtitle(_ event: RuntimeEvent) -> String? {
        if let detail = event.detail {
            if event.previousPID != nil || event.currentPID != nil {
                let pidText = "PID \(event.previousPID.map { String($0) } ?? "-") → \(event.currentPID.map { String($0) } ?? "-")"
                return "\(detail) · \(pidText)"
            }
            return detail
        }
        if event.previousPID != nil || event.currentPID != nil {
            return "PID \(event.previousPID.map { String($0) } ?? "-") → \(event.currentPID.map { String($0) } ?? "-")"
        }
        return nil
    }

    private func eventHelpText(_ event: RuntimeEvent) -> String {
        var lines: [String] = [
            "时间：\(event.timestamp.formatted(date: .abbreviated, time: .standard))",
            "事件：\(event.title)"
        ]
        if let detail = event.detail {
            lines.append("详情：\(detail)")
        }
        if event.previousPID != nil || event.currentPID != nil {
            lines.append("PID：\(event.previousPID.map { String($0) } ?? "-") → \(event.currentPID.map { String($0) } ?? "-")")
        }
        return lines.joined(separator: "\n")
    }
}

private struct WarningBannerBox: View {
    let message: String
    let isError: Bool
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isError ? Theme.danger.icon : Theme.warning.icon)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .textSelection(.enabled)

                Button(isExpanded ? "收起" : "展开全文") {
                    isExpanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isError ? Theme.danger.soft : Theme.warning.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // 重排前的右键复制（2026-11-09 审计补回）。
        .contextMenu {
            Button(isError ? "复制错误" : "复制警告") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message, forType: .string)
            }
        }
    }
}
