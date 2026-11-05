import KongshanCore
import SwiftUI

struct DashboardIdleContent: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                configurationCard
                activityCard
            }
            VStack(spacing: 16) {
                configurationCard
                activityCard
            }
        }
    }

    private var configurationCard: some View {
        GroupBox {
            if let config = state.configItems.first(where: { $0.id == state.activeConfigID }) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(config.name)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        StatusBadge(text: "当前配置", tint: Theme.accent)
                    }

                    LabeledContent("节点", value: "\(config.nodeCount) 个")
                    LabeledContent("策略组", value: "\(state.activeConfigPolicyGroups.count) 个")
                    LabeledContent("当前选择", value: state.selectedNode?.name ?? "未选择")
                    LabeledContent(
                        "最近更新",
                        value: config.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未更新"
                    )

                    if let usage = config.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("套餐用量", value: "\(Theme.bytesOrDash(used)) / \(Theme.bytesOrDash(total))")
                            CapacityBar(fraction: Double(used) / Double(total), tint: Theme.usageTint(Double(used) / Double(total)), height: 5)
                        }
                    }

                    Spacer(minLength: 0)
                    HStack {
                        Button("管理配置") { state.requestPage(.nodes) }
                        Button("选择节点") { state.requestPage(.policyGroups) }
                        Spacer()
                    }
                }
            } else {
                ContentUnavailableView(
                    "还没有生效配置",
                    systemImage: "square.stack.3d.up",
                    description: Text("先在配置页导入订阅或添加节点。")
                )
            }
        } label: {
            Text("配置详情")
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
    }

    private var activityCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                let events = Array(state.runtimeEvents.suffix(5).reversed())
                if events.isEmpty {
                    ContentUnavailableView(
                        "还没有运行记录",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("开启、停止、换网和恢复记录会显示在这里。")
                    )
                } else {
                    ForEach(events) { event in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(event.timestamp, format: .dateTime.hour().minute())
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 42, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                if let detail = event.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .truncationMode(.tail)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)
                        if event.id != events.last?.id { Divider() }
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer()
                    Button("查看全部日志") { state.requestPage(.records) }
                }
            }
        } label: {
            Text("最近活动")
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
    }
}
