import Foundation
import KongshanCore

struct DashboardRoute: Equatable {
    struct Segment: Equatable {
        let title: String
        let value: String
        let detail: String
    }

    let statusTitle: String
    let config: Segment
    let policy: Segment
    let node: Segment
    let exit: Segment?
    let hasTakeover: Bool

    @MainActor
    init(state: AppState) {
        switch state.status {
        case .off:
            statusTitle = "已关闭"
        case .on where state.activeModes.isEmpty:
            statusTitle = "内核就绪 · 未接管"
        case .on:
            statusTitle = state.statusText
        case .starting, .stopping:
            statusTitle = state.statusText
        case .failed:
            statusTitle = "需要处理"
        }

        if let item = state.configItems.first(where: { $0.id == state.activeConfigID }) {
            config = Segment(title: "配置", value: item.name, detail: "\(item.nodeCount) 个节点")
        } else {
            config = Segment(title: "配置", value: "未选择配置", detail: "前往配置")
        }

        policy = Segment(
            title: "策略",
            value: state.primaryGroupName ?? "手动选择",
            detail: "出站 · \(state.outboundMode.displayName)"
        )

        if let selected = state.selectedNode {
            var details = [selected.protocolType.shortName]
            if let delay = state.delays[selected.id] {
                details.append(delay.map { "\($0) ms" } ?? "超时")
            }
            node = Segment(title: "节点", value: selected.name, detail: details.joined(separator: " · "))
        } else {
            node = Segment(title: "节点", value: "未选择节点", detail: "前往代理")
        }

        hasTakeover = state.isOn && !state.activeModes.isEmpty
        if hasTakeover, let report = state.exitDiagnostics {
            exit = Segment(
                title: "出口",
                value: report.exit.location.isEmpty ? report.exit.ip : report.exit.location,
                detail: report.exit.ip
            )
        } else {
            exit = nil
        }
    }
}
