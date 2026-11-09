import AppKit
import Charts
import KongshanCore
import SwiftUI

/// 仪表盘比例规范（2026-11-09 原型：头卡 + 中部两卡撑满到底）。
///
/// 头卡自适应内容高度；「网络流量 / 链路健康」两卡吃掉剩余可视高度（窗口拉高图也跟着高），
/// 内容装不下时整页滚动。所有尺寸集中在这里，调比例只动这一处。
private enum DashboardLayout {
    /// 卡片统一间距。
    static let cardGap: CGFloat = 16
    /// 双主卡宽比 ≈ 63:37（原型 511:297）；右侧只保留链路健康，技术遥测默认收进「运行详情」。
    static let trafficShare: CGFloat = 0.63
    static let overviewShare: CGFloat = 0.37
    /// 右卡最窄 240：960×640 窗口内容宽 732 仍保持两列（280 时阈值 772 会退成单列）。
    static let overviewMinWidth: CGFloat = 240
    static let pagePadding: CGFloat = 20
    static var twoColumnMinWidth: CGFloat { overviewMinWidth / overviewShare + cardGap }
    /// 头卡（状态行 + 链路卡 + 控制行）的近似高度，用于推算中部两卡的撑满高度。
    static let headerBlockHeight: CGFloat = 214
    /// 中部两卡的最小高度：窗口再矮也保得住图表与链路信息的可读性。
    static let middleMinHeight: CGFloat = 300
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
        // 链路模型读 delays / 出口检测，放进 RouteHeaderView 自己构造：整页只看开关状态，
        // 测延迟每回填一批只重算头部卡，不带着整页重排。
        // 布局与接管状态无关（2026-11-09 用户决定）：开关代理只改卡内数值与空态文案，不换卡。
        return GeometryReader { geo in
            let contentWidth = max(0, geo.size.width - DashboardLayout.pagePadding * 2)
            ScrollView {
                VStack(alignment: .leading, spacing: DashboardLayout.cardGap) {
                    RouteHeaderView(isCompact: contentWidth < 680)
                    coreOnlyBanner
                    metrics(gridWidth: contentWidth, viewportHeight: geo.size.height)

                    if state.nodes.isEmpty {
                        ContentUnavailableView {
                            Label {
                                Text("还没有节点")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                            } icon: {
                                Image(systemName: "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        } description: {
                            Text("导入 Clash 订阅，或手动添加一个 Hysteria2 节点。")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textTertiary)
                        } actions: {
                            Button("前往配置页") { state.requestPage(.nodes) }
                                .buttonStyle(.pillProminent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .padding(DashboardLayout.pagePadding)
                // 中部两卡撑满到底：页面内容至少占满可视高，多出的高度由流量/健康两卡吸收。
                .frame(minHeight: max(0, geo.size.height - DashboardLayout.pagePadding * 2), alignment: .top)
            }
        }
        .background(Theme.canvasBackground)
        .foregroundStyle(Theme.textPrimary)
        .groupBoxStyle(CardGroupBoxStyle())
        .labeledContentStyle(CardRowLabeledContentStyle())
        .buttonStyle(.pill)
        .pageTopBar { DashboardToolbarMenu() }
        .onAppear {
            state.startDashboardMonitoring()
            if state.isOn, state.exitDiagnostics == nil {
                Task { await state.refreshExitDiagnostics() }
            }
        }
        .onDisappear { state.stopDashboardMonitoring() }
    }


    // MARK: - 第二层：流量与链路健康

    /// 中部两卡无条件显示（2026-11-09 用户决定：开关代理不换布局）。
    /// 未接管时各卡用卡内空状态：流量数值为「—」、图表区显示空态文案、链路健康保留行骨架。
    private func metrics(gridWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        let metricColumns = gridWidth >= DashboardLayout.twoColumnMinWidth ? 2 : 1
        let shareWidth = gridWidth - DashboardLayout.cardGap
        // 两卡撑满到窗口底：行高至少吃掉头卡以下的全部可视高度。
        let rowMinHeight = max(
            DashboardLayout.middleMinHeight,
            viewportHeight - DashboardLayout.pagePadding * 2 - DashboardLayout.headerBlockHeight - DashboardLayout.cardGap
        )
        return Group {
            if metricColumns == 2 {
                HStack(alignment: .top, spacing: DashboardLayout.cardGap) {
                    DashboardTrafficGroup()
                        .frame(width: shareWidth * DashboardLayout.trafficShare)
                    LinkHealthCard()
                        .frame(width: shareWidth * DashboardLayout.overviewShare)
                }
            } else {
                VStack(spacing: DashboardLayout.cardGap) {
                    DashboardTrafficGroup()
                    LinkHealthCard()
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: metricColumns == 2 ? rowMinHeight : 0, alignment: .topLeading)
    }

    @ViewBuilder
    private var coreOnlyBanner: some View {
        if state.isOn, state.activeModes.isEmpty {
            HStack(spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(Theme.info.icon)
                Text("内核正在运行但未接管网络（仅用于测延迟）。")
                    .font(.callout)
                    .foregroundStyle(Theme.info.text)
                Spacer(minLength: 8)
                Button("停止内核") { Task { await state.stop() } }
                    .controlSize(.small)
                    .disabled(state.isBusy)
            }
            .padding(12)
            .background(Theme.info.soft, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }

    // MARK: - 左主卡：网络流量（紧接整页属性之后，满足 DashboardObservationScopeTests）

    private struct DashboardTrafficGroup: View {
        @State private var range: TrafficRange = .recent

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text("网络流量")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .layoutPriority(2)
                    TrafficLegend()
                    Spacer(minLength: 6)
                    CapsuleSegmentedPicker(options: TrafficRange.allCases, selection: $range) { $0.title }
                        .controlSize(.small)
                        .frame(width: 146)  // 原型宽度，不撑满标题行
                        .layoutPriority(1)
                }

                // 未接管也保留统计行与图表骨架（2026-11-09 用户决定：布局不随开关跳动）：
                // 统计数值为 0 时 Theme 的 …OrDash 显示「—」；图表区由 TrafficPlot 自己的
                // 空态覆盖层占位（「开启系统代理或 TUN 后显示实时流量波形」）。
                TrafficStatsRow(range: range)
                TrafficPlot(range: range)
            }
            .padding(16)
            .frame(
                maxWidth: .infinity,
                minHeight: DashboardLayout.middleMinHeight - 32,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
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

/// 图例：原型只有下/上两个彩色小箭头，文字由统计行与悬浮卡承担。
private struct TrafficLegend: View {
    var body: some View {
        HStack(spacing: 6) {
            legend(symbol: "arrow.down", color: Theme.downloadTint, title: "下载")
            legend(symbol: "arrow.up", color: Theme.uploadTint, title: "上传")
        }
    }

    private func legend(symbol: String, color: Color, title: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .accessibilityLabel(title)
    }
}

/// 统计行：原型三列「本次会话 / 峰值速率 / 平均速率」，11pt 灰标签 + 15pt 半粗大数 + 11pt 附注，列间距 28、无竖线。
private struct TrafficStatsRow: View {
    @Environment(AppState.self) private var state
    let range: TrafficRange

    var body: some View {
        let isOff = !state.isOn
        let points = isOff ? [] : TrafficChartPoint.series(range, state: state)
        let downPeak = isOff ? 0 : (points.map(\.downloadPeak).max() ?? 0)
        let upPeak = isOff ? 0 : (points.map(\.uploadPeak).max() ?? 0)
        let downAverage = isOff || points.isEmpty ? 0 : points.map(\.download).reduce(0, +) / Int64(points.count)
        let upAverage = isOff || points.isEmpty ? 0 : points.map(\.upload).reduce(0, +) / Int64(points.count)
        HStack(alignment: .top, spacing: 28) {
            stat(
                title: "本次会话",
                value: isOff ? "—" : Theme.bytesOrDash(state.sessionTotal),
                detail: isOff ? "↓ —  ↑ —" : "↓ \(Theme.bytesOrDash(state.sessionDownload))  ↑ \(Theme.bytesOrDash(state.sessionUpload))"
            )
            stat(
                title: "峰值速率",
                value: isOff ? "—" : "↓ \(Theme.rateOrDash(downPeak))",
                detail: isOff ? "↑ —" : "↑ \(Theme.rateOrDash(upPeak))"
            )
            stat(
                title: "平均速率",
                value: isOff ? "—" : "↓ \(Theme.rateOrDash(downAverage))",
                detail: isOff ? "↑ —" : "↑ \(Theme.rateOrDash(upAverage))"
            )
            Spacer(minLength: 0)
        }
    }

    private func stat(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            Text(detail)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
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
        if points.isEmpty {
            emptyChartGrid
        } else {
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
                .foregroundStyle(Theme.downloadTint.opacity(0.20))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("速率", point.download),
                    series: .value("方向", "下载线")
                )
                .foregroundStyle(Theme.downloadTint)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("时间", point.time),
                    y: .value("速率", -point.upload),
                    series: .value("方向", "上传")
                )
                .foregroundStyle(Theme.uploadTint.opacity(0.18))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("速率", -point.upload),
                    series: .value("方向", "上传线")
                )
                .foregroundStyle(Theme.uploadTint)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
            }
            if !points.isEmpty {
                RuleMark(y: .value("零", 0))
                    .foregroundStyle(Theme.separator)
                    .lineStyle(StrokeStyle(lineWidth: 0.5))
            }
            if let hovered {
                RuleMark(x: .value("时间", hovered.time))
                    .foregroundStyle(Theme.textTertiary)
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
                AxisGridLine().foregroundStyle(Theme.separator)
                AxisValueLabel {
                    if let bytes = value.as(Int64.self) {
                        Text(bytes == 0 ? "0" : Theme.rate(abs(bytes)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisGridLine().foregroundStyle(Theme.separator)
                if range == .recent {
                    AxisValueLabel(format: .dateTime.minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
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
        }
    }

    private var emptyChartGrid: some View {
        ZStack {
            VStack(spacing: 0) {
                ForEach(0..<5) { index in
                    HStack(spacing: 8) {
                        // 只在最底一条网格线标 0：五条都写 0 看着像坏了（2026-11-09 审计）。
                        Text(index == 4 ? "0" : "")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 28, alignment: .trailing)
                        Theme.separator.frame(height: 0.5)
                    }
                    if index < 4 {
                        Spacer()
                    }
                }
            }
            .padding(.bottom, 22)

            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.cardFill, in: Capsule(style: .circular))
            .overlay(Capsule(style: .circular).strokeBorder(Theme.cardStroke, lineWidth: 0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { transaction in transaction.animation = nil }
    }

    private var emptyText: String {
        guard state.isOn else { return "开启系统代理或 TUN 后显示实时流量波形" }
        return range == .hour ? "每分钟记一个点，稍候片刻" : "等待内核推送流量数据"
    }

    private func hoverCard(_ point: TrafficChartPoint) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(point.time, format: .dateTime.hour().minute().second())
                .font(.caption2)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 3) {
                Text("↓").foregroundStyle(Theme.downloadTint)
                Text(Theme.rateOrDash(point.download)).foregroundStyle(Theme.textPrimary)
            }
            HStack(spacing: 3) {
                Text("↑").foregroundStyle(Theme.uploadTint)
                Text(Theme.rateOrDash(point.upload)).foregroundStyle(Theme.textPrimary)
            }
            if range == .hour {
                Text("峰值 ↓ \(Theme.rateOrDash(point.downloadPeak))")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
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

// MARK: - 右主卡：链路健康（2026-11-09 原型：IP 大字 + 复制、DNS 绿条、风险、活跃连接、卡底警告条）

private struct LinkHealthCard: View {
    @Environment(AppState.self) private var state
    @State private var showsRuntimeDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            exitSection
            Theme.separator.frame(height: 0.5)
            connectionsRow
            DisclosureGroup("运行详情", isExpanded: $showsRuntimeDetails) {
                RuntimeTelemetryGrid()
                    .padding(.top, 8)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            activityFooter
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("链路健康")
                .font(.system(size: 14, weight: .semibold))

            if state.exitDiagnosticsIsStale {
                StatusBadge(text: "切换前", style: Theme.warning)
                    .help("已切换节点，正在探测新出口")
            }

            Spacer(minLength: 4)

            if state.isRefreshingExitDiagnostics {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await state.refreshExitDiagnostics() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("刷新出口 IP 与 DNS 检测")
                .accessibilityLabel("刷新出口检测")
            }

            Button {
                state.requestPage(.diagnostics)
            } label: {
                Text("详细诊断")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
    }

    // 1. 出口 IP 与安全：IP 大字 + 复制、DNS 状态胶囊、位置 / 归属、风险行。
    @ViewBuilder
    private var exitSection: some View {
        if let report = state.exitDiagnostics {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.exit.ip)
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(state.exitDiagnosticsIsStale ? Theme.textSecondary : Theme.textPrimary)
                        .lineLimit(1)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.exit.ip, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制 IP")
                    .accessibilityLabel("复制出口 IP")
                    Spacer(minLength: 0)
                }

                // DNS 状态条：成功时绿点 + 绿字 + 浅绿胶囊底（原型）。
                let dnsStyle = dnsStatusStyle(report.dns.status)
                HStack(spacing: 6) {
                    Circle().fill(dnsStyle.icon).frame(width: 6, height: 6)
                    Text(dnsStatusTitle(report.dns.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(dnsStyle.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(dnsStyle.soft, in: Capsule(style: .circular))

                let loc = [report.exit.location, report.exit.organization].filter { !$0.isEmpty }.joined(separator: " / ")
                Text(loc.isEmpty ? "地理位置与运营商未知" : loc)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if let rep = report.reputation, let risk = rep.risk {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.riskStyle(risk).icon).frame(width: 6, height: 6)
                        Text(Theme.riskSummary(rep))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // 未接管也保留与报告态相同的行骨架（IP 行 / DNS 胶囊 / 说明行 / 风险行），
            // 只把数值换成占位，卡片高度与布局不随接管状态跳动（2026-11-09 用户决定）。
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("—")
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    if state.isRefreshingExitDiagnostics {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("立即检测") {
                            Task { await state.refreshExitDiagnostics() }
                        }
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                // DNS 胶囊占位：中性样式，未接管时没有检测结论。
                HStack(spacing: 6) {
                    Circle().fill(Theme.neutral.icon).frame(width: 6, height: 6)
                    Text("DNS 未检测")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.neutral.text)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.neutral.soft, in: Capsule(style: .circular))

                Text(idleExitDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(state.exitDiagnosticsError == nil || state.isRefreshingExitDiagnostics ? Theme.textSecondary : Theme.warning.text)
                    .lineLimit(2)

                // 风险行占位：报告态这里是有声誉分时的风险摘要。
                HStack(spacing: 6) {
                    Circle().fill(Theme.neutral.icon).frame(width: 6, height: 6)
                    Text("风险未评估")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 未接管时链路健康卡的说明：沿用原空态文案，按状态给提示或错误。
    private var idleExitDetail: String {
        if state.isRefreshingExitDiagnostics { return "正在探测出口网络…" }
        if let error = state.exitDiagnosticsError { return error }
        return state.isOn
            ? "点击右侧按钮检测当前出口 IP、归属地与 DNS 泄漏状态。"
            : "开启系统代理或 TUN 后会自动检测出口 IP 与 DNS。"
    }

    // 2. 活跃连接行：点击前往连接页。
    private var connectionsRow: some View {
        Button {
            state.requestPage(.connections)
        } label: {
            HStack {
                Text("活跃连接")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                ActiveConnectionCountText()
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // 3. 卡底警告条：错误红底、警告橙底、无通知时显示最新运行事件或「运行平稳」。
    @ViewBuilder
    private var activityFooter: some View {
        if let error = state.errorMessage {
            noticeBar(text: error, symbol: "exclamationmark.octagon.fill", style: Theme.danger)
        } else if let warning = state.warnings.last {
            noticeBar(text: warning, symbol: "exclamationmark.triangle.fill", style: Theme.warning)
        } else {
            HStack(spacing: 6) {
                if let event = state.runtimeEvents.last {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Text(event.detail.map { "\($0.isEmpty ? event.title : "\(event.title) · \($0)")" } ?? event.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.success.icon)
                    Text("运行平稳，无未处理告警")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                allLogsLink
            }
        }
    }

    private func noticeBar(text: String, symbol: String, style: Theme.SemanticColors) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(style.icon)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("清除") {
                state.dismissError()
                state.clearWarnings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize()
            allLogsLink
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(style.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var allLogsLink: some View {
        Button {
            state.requestPage(.records)
        } label: {
            HStack(spacing: 2) {
                Text("全部日志")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func dnsStatusTitle(_ status: DNSLeakStatus) -> String {
        switch status {
        case .clear: "DNS 未见泄漏"
        case .possible: "DNS 可能泄漏"
        case .indeterminate: "DNS 待判定"
        }
    }

    private func dnsStatusStyle(_ status: DNSLeakStatus) -> Theme.SemanticColors {
        switch status {
        case .clear: Theme.success
        case .possible: Theme.warning
        case .indeterminate: Theme.neutral
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Theme.rateOrDash(value))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .fixedSize()
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
                        .foregroundStyle(Theme.textSecondary)
                    RuntimeDurationLabel()
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(state.isOn ? "本次持续接管" : "等待开启接管")
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
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
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
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
