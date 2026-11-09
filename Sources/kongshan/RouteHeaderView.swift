import KongshanCore
import SwiftUI

struct RouteHeaderView: View {
    @Environment(AppState.self) private var state
    let isCompact: Bool

    private var statusStyle: Theme.SemanticColors {
        switch state.status {
        case .on: Theme.current
        case .starting, .stopping: Theme.warning
        case .failed: Theme.danger
        case .off: Theme.neutral
        }
    }

    /// 链路模型在这里构造而不是由仪表盘传入：它读 `delays` 与出口检测，
    /// 只让这张卡跟着失效（`DashboardObservationScopeTests`）。
    var body: some View {
        let _ = Self.noteBodyEvaluation()
        let route = DashboardRoute(state: state)
        return GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 8) {
                    Circle()
                        .fill(statusStyle.icon)
                        .frame(width: 9, height: 9)
                    Text(route.statusTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
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

                controlRow
            }
            // 卡片内边距 16（GroupBox 样式）+ 2 = 原型的 18。
            .padding(2)
        }
    }

    private func horizontalRoute(_ route: DashboardRoute) -> some View {
        HStack(alignment: .center, spacing: 8) {
            routeSegment(route.config, page: .nodes)
            routeArrow
            routeSegment(route.policy, page: .policyGroups)
            routeArrow
            routeSegment(route.node, page: .policyGroups)
            routeArrow
            routeSegment(exitSegment(route), page: .diagnostics)
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
                compactSegment(exitSegment(route), page: .diagnostics)
            }
            DashboardLiveRatePair()
        }
    }

    /// 「出口」一段未接管也照常占位（2026-11-09 用户决定：链路卡四段不随开关增减）：
    /// 无报告显示「—」；已接管但还没探测完写「检测中」，未接管写「未接管」。
    private func exitSegment(_ route: DashboardRoute) -> DashboardRoute.Segment {
        route.exit ?? DashboardRoute.Segment(
            title: "出口",
            value: "—",
            detail: route.hasTakeover ? "检测中…" : "未接管"
        )
    }

    private var routeArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityHidden(true)
    }

    /// 链路卡：画布灰底圆角 10，标签 11 / 值 13 半粗 / 附注 11（原型）。
    private func routeSegment(_ segment: DashboardRoute.Segment, page: SidebarPage) -> some View {
        Button {
            if page == .policyGroups, let group = state.primaryGroupName {
                state.proxyPageGroupName = group
            }
            state.requestPage(page)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(segment.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Text(segment.value)
                    .font(.system(size: 13, weight: .semibold, design: page == .diagnostics ? .monospaced : .default))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(segment.detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(Theme.canvasBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityLabel("\(segment.title)：\(segment.value)，\(segment.detail)")
        .help("\(segment.title)：\(segment.value)，\(segment.detail)")
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
            // 原型 164 宽的紧凑分段，不随卡片拉满。
            .frame(width: 164)
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
        // 「断开全部」常驻、未接管时禁用（2026-11-09 用户决定）：随开关出现/消失会让控制行宽度跳动。
        Button(role: .destructive) {
            Task { await state.stop() }
        } label: {
            Label("断开全部", systemImage: "power")
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!state.isOn || state.isBusy)
    }

    /// 标签 12pt 在左、开关在右的紧凑接管开关（原型 controls 行）。
    private func modeToggle(title: String, mode: ProxyMode) -> some View {
        Toggle(title, isOn: state.takeoverModeBinding(mode))
            .font(.system(size: 12))
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
