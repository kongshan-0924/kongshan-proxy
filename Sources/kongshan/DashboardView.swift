import Charts
import KongshanCore
import SwiftUI

/// 双主卡目标高度，由 `DashboardView` 量出可视区后下发，两张主卡各自读取。
private enum DashboardCardHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 320
}

private extension EnvironmentValues {
    var dashboardCardHeight: CGFloat {
        get { self[DashboardCardHeightKey.self] }
        set { self[DashboardCardHeightKey.self] = newValue }
    }
}

/// 仪表盘比例规范（参考 ClashX / Surge / V2rayU 等主流代理客户端的紧凑单窗范式）。
///
/// 核心思路：**默认窗口按 4:3，内容贴紧不撑满，卡片高宽成比、间距统一，窄了竖排**——
/// 这样窗口怎么拉，内容始终维持固有比例，多出的空间统一留成外边距，画面不会"怪"。
/// 所有尺寸集中在这里，调比例只动这一处。
private enum DashboardLayout {
    /// 卡片统一圆角与间距节奏（8 的倍数）。
    static let cardGap: CGFloat = 16
    /// 双主卡宽比 3:2；右侧只保留链路健康，技术遥测默认收进「运行详情」。
    static let trafficShare: CGFloat = 0.6
    static let overviewShare: CGFloat = 0.4
    static let overviewMinWidth: CGFloat = 260
    static let horizontalPadding: CGFloat = 20
    static var twoColumnMinWidth: CGFloat { overviewMinWidth / overviewShare + cardGap }
    /// 有数据时让图表利用可视高度；没有数据时由 `cardHeight` 使用紧凑占位。
    static let reservedVertical: CGFloat = 230
}

/// 仪表盘（简洁大气、零嵌套灰块的原生 macOS 架构）。
///
/// **高频状态一律不在整页作用域里读**：速率（两秒一变）、活跃连接、内核内存、空山占用、
/// 出口检测各自成一个小视图，Observation 只失效读到它的那一块。
/// `DashboardObservationScopeTests` 用 body 求值计数钉住这条性质。
struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let _ = Self.noteBodyEvaluation()
        // 链路模型读 delays / 出口检测，放进 RouteHeaderView 自己构造：整页只看接管与否，
        // 测延迟每回填一批只重算头部卡，不带着整页重排。
        let hasTakeover = state.isOn && !state.activeModes.isEmpty
        return GeometryReader { geo in
            let contentWidth = max(0, geo.size.width - DashboardLayout.horizontalPadding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RouteHeaderView(isCompact: contentWidth < 680)
                    coreOnlyBanner
                    if !hasTakeover, !state.nodes.isEmpty {
                        DashboardIdleContent()
                    }
                    metrics(gridWidth: contentWidth, hasTakeover: hasTakeover)

                    if state.nodes.isEmpty {
                        ContentUnavailableView {
                            Label("还没有节点", systemImage: "point.3.connected.trianglepath.dotted")
                        } description: {
                            Text("导入 Clash 订阅，或手动添加一个 Hysteria2 节点。")
                        } actions: {
                            Button("前往配置页") { state.requestPage(.nodes) }
                                .buttonStyle(.pillProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .padding(.horizontal, DashboardLayout.horizontalPadding)
                .padding(.top, 20)
                .padding(.bottom, 30)
            }
            .environment(\.dashboardCardHeight, cardHeight(viewportHeight: geo.size.height))
        }
        .background(Theme.canvasBackground)
        .groupBoxStyle(CardGroupBoxStyle())
        .buttonStyle(.pill)
        .navigationTitle("仪表盘")
        .navigationSubtitle(subtitle)
        .onAppear {
            state.startDashboardMonitoring()
            if state.isOn, state.exitDiagnostics == nil {
                Task { await state.refreshExitDiagnostics() }
            }
        }
        .onDisappear { state.stopDashboardMonitoring() }
    }

    private var subtitle: String {
        guard state.isOn else { return state.statusText }
        return "\(state.statusText) · \(state.selectedNode?.name ?? "未选择节点")"
    }

    private func cardHeight(viewportHeight: CGFloat) -> CGFloat {
        min(320, max(260, viewportHeight - DashboardLayout.reservedVertical))
    }

    // MARK: - 第二层：流量与链路健康

    @ViewBuilder
    private func metrics(gridWidth: CGFloat, hasTakeover: Bool) -> some View {
        if hasTakeover {
            let metricColumns = gridWidth >= DashboardLayout.twoColumnMinWidth ? 2 : 1
            let shareWidth = gridWidth - DashboardLayout.cardGap
            Group {
                if metricColumns == 2 {
                    HStack(alignment: .top, spacing: DashboardLayout.cardGap) {
                        DashboardTrafficGroup()
                            .frame(width: shareWidth * DashboardLayout.trafficShare)
                        OverviewCardBox()
                            .frame(width: shareWidth * DashboardLayout.overviewShare)
                    }
                    // 两卡取较高者等高：左卡没数据时的紧凑占位不再把右卡压扁。
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: DashboardLayout.cardGap) {
                        DashboardTrafficGroup()
                        OverviewCardBox()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var coreOnlyBanner: some View {
        if state.isOn, state.activeModes.isEmpty {
            HStack(spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("内核正在运行但未接管网络（仅用于测延迟）。")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("停止内核") { Task { await state.stop() } }
                    .controlSize(.small)
                    .disabled(state.isBusy)
            }
            .padding(12)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color.blue.opacity(0.30), lineWidth: 1))
        }
    }

    // MARK: - 左主卡：网络流量（紧接整页属性之后，满足 DashboardObservationScopeTests）

    private struct DashboardTrafficGroup: View {
        @State private var range: TrafficRange = .recent
        @Environment(AppState.self) private var state
        @Environment(\.dashboardCardHeight) private var cardHeight

        private var hasData: Bool {
            !state.trafficHistory.isEmpty || !state.trafficMinutes.isEmpty
        }

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text("网络流量")
                            .font(.headline)
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 6)
                        TrafficLegend()
                        CapsuleSegmentedPicker(options: TrafficRange.allCases, selection: $range) { $0.title }
                            .fixedSize()
                    }

                    Divider()

                    if hasData {
                        TrafficStatsRow(range: range)
                        TrafficPlot(range: range)
                    } else {
                        ContentUnavailableView {
                            Label("等待流量数据", systemImage: "chart.xyaxis.line")
                        } description: {
                            Text("内核推送第一批数据后开始绘制波形。")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(4)
                .frame(
                    maxWidth: .infinity,
                    minHeight: hasData ? cardHeight : 160,
                    // 没数据时可以被右卡撑高（两卡等高），有数据时图表固定高度。
                    maxHeight: hasData ? cardHeight : .infinity,
                    alignment: .topLeading
                )
            }
        }
    }
}

enum TrafficRange: String, CaseIterable, Identifiable {
    case recent
    case hour

    var id: Self { self }
    var title: String { self == .recent ? "近 4 分钟" : "近 1 小时" }
}

struct TrafficChartPoint: Identifiable, Equatable {
    let time: Date
    let upload: Int64
    let download: Int64
    let uploadPeak: Int64
    let downloadPeak: Int64

    var id: Date { time }

    @MainActor static func series(_ range: TrafficRange, state: AppState) -> [TrafficChartPoint] {
        switch range {
        case .recent:
            state.trafficHistory.map {
                TrafficChartPoint(time: $0.timestamp, upload: $0.upload, download: $0.download,
                                  uploadPeak: $0.upload, downloadPeak: $0.download)
            }
        case .hour:
            state.trafficMinutes.map {
                TrafficChartPoint(time: $0.start, upload: $0.uploadAverage, download: $0.downloadAverage,
                                  uploadPeak: $0.uploadPeak, downloadPeak: $0.downloadPeak)
            }
        }
    }
}

private struct TrafficLegend: View {
    var body: some View {
        HStack(spacing: 10) {
            legend(symbol: "arrow.down", color: Theme.downloadTint, title: "下载")
            legend(symbol: "arrow.up", color: Theme.uploadTint, title: "上传")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func legend(symbol: String, color: Color, title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 统计行：直接排在白卡上，不套灰色胶囊壳，大号等宽数字清晰大气。
private struct TrafficStatsRow: View {
    @Environment(AppState.self) private var state
    let range: TrafficRange

    var body: some View {
        let points = TrafficChartPoint.series(range, state: state)
        let downPeak = points.map(\.downloadPeak).max() ?? 0
        let upPeak = points.map(\.uploadPeak).max() ?? 0
        let downAverage = points.isEmpty ? 0 : points.map(\.download).reduce(0, +) / Int64(points.count)
        let upAverage = points.isEmpty ? 0 : points.map(\.upload).reduce(0, +) / Int64(points.count)
        HStack(alignment: .top, spacing: 0) {
            stat(
                title: "本次会话",
                value: Theme.bytesOrDash(state.sessionTotal),
                detail: "↓ \(Theme.bytesOrDash(state.sessionDownload))  ↑ \(Theme.bytesOrDash(state.sessionUpload))"
            )
            Spacer(minLength: 12)
            Divider().frame(height: 36)
            Spacer(minLength: 12)
            stat(
                title: "峰值速率",
                value: "↓ \(Theme.rateOrDash(downPeak))",
                detail: "↑ \(Theme.rateOrDash(upPeak))"
            )
            Spacer(minLength: 12)
            Divider().frame(height: 36)
            Spacer(minLength: 12)
            stat(
                title: "平均速率",
                value: "↓ \(Theme.rateOrDash(downAverage))",
                detail: "↑ \(Theme.rateOrDash(upAverage))"
            )
            Spacer(minLength: 0)
        }
    }

    private func stat(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// 波形图：直接画在白卡画布上，去掉灰框底块，视觉瞬间通透。
private struct TrafficPlot: View {
    @Environment(AppState.self) private var state
    let range: TrafficRange
    @State private var hoverTime: Date?

    var body: some View {
        let points = TrafficChartPoint.series(range, state: state)
        let hovered = hoverTime.flatMap { time in
            points.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
        }
        Chart {
            ForEach(points) { point in
                AreaMark(
                    x: .value("时间", point.time),
                    y: .value("速率", point.download),
                    series: .value("方向", "下载")
                )
                .foregroundStyle(.green.opacity(0.20))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("速率", point.download),
                    series: .value("方向", "下载线")
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("时间", point.time),
                    y: .value("速率", -point.upload),
                    series: .value("方向", "上传")
                )
                .foregroundStyle(.blue.opacity(0.18))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("速率", -point.upload),
                    series: .value("方向", "上传线")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
            }
            if !points.isEmpty {
                RuleMark(y: .value("零", 0))
                    .foregroundStyle(.secondary.opacity(0.40))
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            if let hovered {
                RuleMark(x: .value("时间", hovered.time))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        hoverCard(hovered)
                    }
            }
        }
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(bytes == 0 ? "0" : Theme.rate(abs(bytes)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(.quaternary)
                if range == .recent {
                    AxisValueLabel(format: .dateTime.minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(location):
                            guard let frame = proxy.plotFrame else { return }
                            let x = location.x - geometry[frame].origin.x
                            hoverTime = proxy.value(atX: x, as: Date.self)
                        case .ended:
                            hoverTime = nil
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in transaction.animation = nil }
        .overlay {
            if points.isEmpty {
                ZStack {
                    VStack(spacing: 46) {
                        Divider().opacity(0.45)
                        Divider().opacity(0.45)
                        Divider().opacity(0.45)
                    }

                    VStack(spacing: 6) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text(emptyText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Theme.cardFill.opacity(0.92), in: Capsule(style: .circular))
                }
            }
        }
    }

    private var emptyText: String {
        guard state.isOn else { return "开启系统代理或 TUN 后显示实时流量波形" }
        return range == .hour ? "每分钟记一个点，稍候片刻" : "等待内核推送流量数据"
    }

    private func hoverCard(_ point: TrafficChartPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.time, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("↓ \(Theme.rateOrDash(point.download))")
                .foregroundStyle(.green)
            Text("↑ \(Theme.rateOrDash(point.upload))")
                .foregroundStyle(.blue)
            if range == .hour {
                Text("峰值 ↓ \(Theme.rateOrDash(point.downloadPeak))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // 悬浮卡用白卡底而非系统材质：与全 App 卡片语言一致（全 App 唯一一处材质块）。
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
    }
}

// MARK: - 右主卡：出口与运行状态（OverviewCardBox，全白卡内用十字细线分割，彻底去掉灰底小方块）

private struct OverviewCardBox: View {
    @Environment(AppState.self) private var state
    @State private var showsRuntimeDetails = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                Divider()
                exitSection
                Divider()
                Button {
                    state.requestPage(.connections)
                } label: {
                    LabeledContent("活跃连接") { ActiveConnectionCountText() }
                        .font(.callout)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                DisclosureGroup("运行详情", isExpanded: $showsRuntimeDetails) {
                    RuntimeTelemetryGrid()
                        .padding(.top, 8)
                }
                .font(.callout)
                Spacer(minLength: 0)
                Divider()
                activityFooter
            }
            .padding(4)
            // 高度不封顶：没流量数据时左卡只有 160 高，这里若跟着封顶，出口、运行详情与底栏会溢出卡外。
            // 两卡等高由外层 HStack 的 fixedSize 统一，本卡只把多出的高度留给 Spacer。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("链路健康")
                .font(.headline)

            if state.exitDiagnosticsIsStale {
                StatusBadge(text: "切换前", tint: .orange)
                    .help("已切换节点，正在探测新出口")
            }

            Spacer()

            if state.isRefreshingExitDiagnostics {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await state.refreshExitDiagnostics() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("刷新出口 IP 与 DNS 检测")
            }

            Button {
                state.requestPage(.diagnostics)
            } label: {
                HStack(spacing: 3) {
                    Text("详细诊断")
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // 1. 出口 IP 与安全（直接排版在白卡上，不套灰框）
    @ViewBuilder
    private var exitSection: some View {
        if let report = state.exitDiagnostics {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.exit.ip)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(state.exitDiagnosticsIsStale ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Spacer()
                    StatusBadge(text: dnsStatusTitle(report.dns.status), tint: dnsStatusTint(report.dns.status))
                }
                let loc = [report.exit.location, report.exit.organization].filter { !$0.isEmpty }.joined(separator: " · ")
                Text(loc.isEmpty ? "地理位置与运营商未知" : loc)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let rep = report.reputation, let risk = rep.risk {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.riskTint(risk)).frame(width: 6, height: 6)
                        Text(Theme.riskSummary(rep))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.riskTint(risk))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        } else {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.isRefreshingExitDiagnostics ? "正在探测出口网络…" : (state.exitDiagnosticsError == nil ? "未接管网络" : "出口探测未完成"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(state.exitDiagnosticsError == nil ? Color.primary : Color.orange)
                    Text(state.exitDiagnosticsError ?? (state.isOn ? "点击右侧按钮检测当前出口 IP、归属地与 DNS 泄漏状态。" : "开启系统代理或 TUN 后会自动检测出口 IP 与 DNS。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if !state.isRefreshingExitDiagnostics {
                    Button("立即检测") {
                        Task { await state.refreshExitDiagnostics() }
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
    }

    // 3. 底部单行运行动态栏
    private var noticeCount: Int {
        (state.errorMessage != nil ? 1 : 0) + state.warnings.count
    }

    private var activityFooter: some View {
        HStack(spacing: 8) {
            if let error = state.errorMessage {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let warning = state.warnings.last {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let event = state.runtimeEvents.last {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(event.detail.map { "\($0.isEmpty ? event.title : "\(event.title) · \($0)")" } ?? event.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text("运行平稳，无未处理告警")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if noticeCount > 0 {
                Button("清除") {
                    state.dismissError()
                    state.clearWarnings()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }

            Button {
                state.requestPage(.records)
            } label: {
                HStack(spacing: 3) {
                    Text("全部日志")
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func dnsStatusTitle(_ status: DNSLeakStatus) -> String {
        switch status {
        case .clear: "DNS 未见泄漏"
        case .possible: "DNS 可能泄漏"
        case .indeterminate: "DNS 待判定"
        }
    }

    private func dnsStatusTint(_ status: DNSLeakStatus) -> Color {
        switch status {
        case .clear: .green
        case .possible: .orange
        case .indeterminate: .secondary
        }
    }
}

// MARK: - 会变的小块（顶部大号双通道速率表头，不套灰框）

struct DashboardLiveRatePair: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let _ = Self.noteBodyEvaluation()
        HStack(spacing: 20) {
            rateColumn(symbol: "arrow.up", tint: Theme.uploadTint, title: "上传", value: state.uploadRate)
            rateColumn(symbol: "arrow.down", tint: Theme.downloadTint, title: "下载", value: state.downloadRate)
        }
    }

    private func rateColumn(symbol: String, tint: Color, title: String, value: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Theme.rateOrDash(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 108, alignment: .leading)
    }
}

/// 活跃连接数，每秒变：单独成视图，只有这一小块跟着重算（`DashboardObservationScopeTests`）。
private struct ActiveConnectionCountText: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Text("\(state.activeConnectionCount) 条")
            .monospacedDigit()
    }
}

/// 「运行详情」展开后的四项遥测：连接、内存、负载、时长都是高频值，单独成视图不带着整张卡重算。
private struct RuntimeTelemetryGrid: View {
    @Environment(AppState.self) private var state

    // 2. 四项系统遥测指标：用干净的十字细线（Crosshair Divider）分割，不再套 4 个灰色补丁块
    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                cleanMetricCell(
                    title: "活跃连接",
                    value: "\(state.activeConnectionCount)",
                    subtitle: "累计 \(Theme.bytesOrDash(state.sessionTotal))"
                )
                .contentShape(Rectangle())
                .onTapGesture { state.requestPage(.connections) }
                .help("点击前往连接页")

                Divider().frame(height: 48)

                cleanMetricCell(
                    title: "内存（内核 / 空山）",
                    value: memoryText,
                    subtitle: state.coreVersion == "—" ? "sing-box 待命" : "内核 \(state.coreVersion)"
                )
            }

            Divider()

            HStack(alignment: .top, spacing: 16) {
                cleanMetricCell(
                    title: "客户端负载",
                    value: state.lastMetrics.map { String(format: "%.1f%%", $0.cpu) } ?? "0.0%",
                    subtitle: "每分钟采样一次"
                )

                Divider().frame(height: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text("运行时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    RuntimeDurationLabel()
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(state.isOn ? "本次持续接管" : "等待开启接管")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var memoryText: String {
        let core = Theme.bytesOrDash(Int64(clamping: state.coreMemory))
        let app = state.lastMetrics.map { "\($0.rss) MB" } ?? "—"
        return "\(core) / \(app)"
    }

    private func cleanMetricCell(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 运行时长。
private struct RuntimeDurationLabel: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if state.isOn, let startedAt = state.runtimeStartedAt {
            TimelineView(.everyMinute) { context in
                Text(Self.text(since: startedAt, now: context.date))
            }
        } else {
            Text("—")
        }
    }

    static func text(since start: Date, now: Date) -> String {
        let seconds = Int(max(now.timeIntervalSince(start), 0))
        if seconds < 60 { return "刚启动" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) 小时 \(minutes % 60) 分" }
        return "\(hours / 24) 天 \(hours % 24) 小时"
    }
}

// MARK: - body 求值计数（测试用）

#if DEBUG
extension DashboardView {
    @MainActor static var bodyEvaluations = 0
}

extension DashboardLiveRatePair {
    @MainActor static var bodyEvaluations = 0
}
#endif

extension DashboardView {
    @MainActor static func noteBodyEvaluation() {
        #if DEBUG
        bodyEvaluations += 1
        #endif
    }
}

extension DashboardLiveRatePair {
    @MainActor static func noteBodyEvaluation() {
        #if DEBUG
        bodyEvaluations += 1
        #endif
    }
}
