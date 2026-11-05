import KongshanCore
import SwiftUI

struct RouteHeaderView: View {
    @Environment(AppState.self) private var state
    let isCompact: Bool

    /// 链路模型在这里构造而不是由仪表盘传入：它读 `delays` 与出口检测，
    /// 只让这张卡跟着失效（`DashboardObservationScopeTests`）。
    var body: some View {
        let _ = Self.noteBodyEvaluation()
        let route = DashboardRoute(state: state)
        return GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 12) {
                    Circle()
                        .fill(state.statusTint)
                        .frame(width: 9, height: 9)
                    Text(route.statusTitle)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 12)
                    if !isCompact {
                        DashboardLiveRatePair()
                    }
                }

                if isCompact {
                    compactRoute(route)
                } else {
                    horizontalRoute(route)
                }

                Divider()
                controlRow
            }
            .padding(4)
        }
    }

    private func horizontalRoute(_ route: DashboardRoute) -> some View {
        HStack(alignment: .center, spacing: 8) {
            routeSegment(route.config, page: .nodes)
            routeArrow
            routeSegment(route.policy, page: .policyGroups)
            routeArrow
            routeSegment(route.node, page: .policyGroups)
            if let exit = route.exit {
                routeArrow
                routeSegment(exit, page: .diagnostics)
            }
        }
    }

    private func compactRoute(_ route: DashboardRoute) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                compactSegment(route.config, page: .nodes)
                compactSegment(route.policy, page: .policyGroups)
            }
            HStack(spacing: 8) {
                compactSegment(route.node, page: .policyGroups)
                if let exit = route.exit {
                    compactSegment(exit, page: .diagnostics)
                }
            }
            DashboardLiveRatePair()
        }
    }

    private var routeArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func routeSegment(_ segment: DashboardRoute.Segment, page: SidebarPage) -> some View {
        Button {
            if page == .policyGroups, let group = state.primaryGroupName {
                state.proxyPageGroupName = group
            }
            state.requestPage(page)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(segment.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(segment.value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(segment.detail)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Theme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("\(segment.title)：\(segment.value)，\(segment.detail)")
    }

    private func compactSegment(_ segment: DashboardRoute.Segment, page: SidebarPage) -> some View {
        routeSegment(segment, page: page)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controlRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                outboundPicker
                Spacer(minLength: 16)
                takeoverControls
            }
            VStack(alignment: .leading, spacing: 10) {
                outboundPicker
                HStack(spacing: 16) {
                    takeoverControls
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var outboundPicker: some View {
        CapsuleSegmentedPicker(options: OutboundMode.allCases, selection: state.outboundModeBinding) { $0.displayName }
            .frame(width: 210)
            .help(state.outboundMode.detail)
            .disabled(state.isBusy || !state.isReady)
    }

    @ViewBuilder
    private var takeoverControls: some View {
        if state.isBusy {
            ProgressView()
                .controlSize(.small)
                .help(state.statusText)
        }
        modeToggle(title: ProxyMode.systemProxy.displayName, mode: .systemProxy)
        modeToggle(title: ProxyMode.tun.displayName, mode: .tun)
        if state.isOn {
            Button {
                Task { await state.stop() }
            } label: {
                Label("断开全部", systemImage: "power")
            }
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(state.isBusy)
        }
    }

    private func modeToggle(title: String, mode: ProxyMode) -> some View {
        Toggle(title, isOn: state.takeoverModeBinding(mode))
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(state.isBusy || !state.isReady)
    }
}

extension RouteHeaderView {
    #if DEBUG
    @MainActor static var bodyEvaluations = 0
    #endif

    @MainActor static func noteBodyEvaluation() {
        #if DEBUG
        bodyEvaluations += 1
        #endif
    }
}
