import Charts
import KongshanCore
import SwiftUI

/// 仪表盘。
///
/// **高频状态一律不在整页作用域里读**：速率（两秒一变）、活跃连接、内核内存、空山占用、
/// 出口检测各自成一个小视图，Observation 只失效读到它的那一块。此前这些值都在整页 `body`
/// 的计算属性里读，任何一个变一下，状态区、六张指标卡、图表容器整页重排——真机 2026-09-03
/// 指标流水：仪表盘可见时 CPU 中位 6.3%，其它页 1.5%，差的这一截主要就是这个。
/// `DashboardObservationScopeTests` 用 body 求值计数钉住这条性质。
struct DashboardView: View {
    @State private var headerWidth: CGFloat = 0
    @Environment(AppState.self) private var state
    @State private var metricColumns = 3

    var body: some View {
        let _ = Self.noteBodyEvaluation()
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusGroup
                coreOnlyBanner
                metrics
                DashboardTrafficGroup()

                if state.nodes.isEmpty {
                    // 空态直接给出口，不让用户自己去侧栏找「配置」在哪。
                    ContentUnavailableView {
                        Label("还没有节点", systemImage: "point.3.connected.trianglepath.dotted")
                    } description: {
                        Text("导入 Clash 订阅，或手动添加一个 Hysteria2 节点。")
                    } actions: {
                        Button("前往配置页") { state.requestPage(.nodes) }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            .padding(20)
        }
        .groupBoxStyle(CardGroupBoxStyle())
        .navigationTitle("仪表盘")
        .navigationSubtitle(subtitle)
        .onAppear {
            state.startDashboardMonitoring()
            // 只在代理开启时自动检测出口：代理关闭时 refreshExitDiagnostics 会用真实 IP
            // 直连 am.i.mullvad.net 并做 3 次 DNS 解析，且此时出口就是本机、无诊断意义。
            // 手动「检测」按钮仍可用；start() 成功后与切主节点时也会自动触发。
            if state.isOn, state.exitDiagnostics == nil {
                Task { await state.refreshExitDiagnostics() }
            }
        }
        .onDisappear { state.stopDashboardMonitoring() }
    }

    /// 副标题放在原生标题栏里：邮件写"收件箱 — 12 封"，这里写状态与节点。
    private var subtitle: String {
        guard state.isOn else { return state.statusText }
        return "\(state.statusText) · \(state.selectedNode?.name ?? "未选择节点")"
    }

    // MARK: - 状态与控制

    /// 状态点 + 状态文字 + 出站徽标；第二行节点 · 协议 · 延迟 · 配置。
    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.statusTint)
                    .frame(width: 9, height: 9)
    Text(state.statusText)
        .font(.title3.weight(.semibold))
    if state.isOn {
        StatusBadge(text: "出站 · \(state.outboundMode.displayName)", tint: state.statusTint)
    }
            }
            HStack(spacing: 6) {
    if let selected = state.selectedNode {
        Text(selected.name)
            .font(.callout)
            .lineLimit(1)
        ProtocolTag(value: selected.protocolType)
        // 延迟单独成视图：测速时 `delays` 每秒回填好几批，在这里读会带着整页重算。
        SelectedNodeDelayLabel(nodeID: selected.id)
    } else {
        Text("未启用或未选择节点")
            .font(.callout)
            .foregroundStyle(.secondary)
    }
    // 当前配置紧挨节点：这两条是同一个问题的两半——"用哪个配置里的哪个节点"。
    // 原来配置单占一张指标卡，既占位置又和节点隔着半屏。
    if let config = activeConfig {
        Divider().frame(height: 12)
        Text(config.name)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
            .help("当前生效配置")
        Text("\(config.nodeCount) 个节点")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
            }
    }
    }

    /// 状态卡头部一行能否放下。阈值来自内容实测：身份列（国旗+节点名+协议标签+延迟+配置名+节点数）
    /// 约 340pt，速率对约 230pt，中间留 24pt，合计约 594pt——取 600 作分界。
    /// 节点名超长时判断会偏乐观，那时退化成截断，与改动前一致，不会更糟。
    private static let headerOneLineMinimum: CGFloat = 600

    private var headerFitsOneLine: Bool {
        headerWidth == 0 || headerWidth >= Self.headerOneLineMinimum
    }

    private var statusGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                // 窄窗口下「节点 · 配置」和「上传 / 下载」挤不进一行时换行，
                // 而不是两边一起截成「香港 IE…」「cdn.…de.org」——那种谁也没让步的截断最难看。
                //
                // **不用 `ViewThatFits`**：它要把每个候选都测一遍才能选，而两个候选里都含
                // 每秒跳动的 `DashboardLiveRatePair`——于是每次速率更新都要多测几棵子树。
                // 实测（`RateUpdateCostTests`）：每次更新的速率视图 body 求值从 0.55 涨到 1.65，
                // 三倍；真机同条件（TUN+系统代理、仪表盘可见）CPU 中位数从 1.7~2.1% 跳到 4.09%。
                // 仪表盘是最常开着的一页，这个代价不值。
                //
                // 改成按宽度决策：宽度只在**改窗口大小**时变，速率每秒变也不会重新判。
                // 背景里的 GeometryReader 只读尺寸、不参与布局。
                if headerFitsOneLine {
                    HStack(alignment: .center, spacing: 14) {
                        identityColumn
                        Spacer(minLength: 24)
                        DashboardLiveRatePair()
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        identityColumn
                        DashboardLiveRatePair()
                    }
                }

                Divider()

                HStack(spacing: 14) {
                    Picker("出站模式", selection: state.outboundModeBinding) {
                        ForEach(OutboundMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    // 弹性宽度：窄窗口下让位给开关与断开按钮，宽窗口下最多 240；
                    // 内容靠左，与上方状态文字对齐，不在框内居中。
                    .frame(minWidth: 150, maxWidth: 240, alignment: .leading)
                    .help(state.outboundMode.detail)
                    .disabled(state.isBusy || !state.isReady)

                    Spacer()

                    // 启停要几秒（TUN 要换 root 内核）：转个圈说明在干活，而不是界面卡住。
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
                        .disabled(state.isBusy)
                    }
                }
            }
            .padding(4)
            // 只读宽度，不参与布局；仅在改窗口大小时触发。
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { headerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in headerWidth = width }
                }
            }
        }
    }

    private func modeToggle(title: String, mode: ProxyMode) -> some View {
        Toggle(title, isOn: state.takeoverModeBinding(mode))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(state.isBusy || !state.isReady)
    }

    // MARK: - 指标

    /// 接管方式、当前节点与出站模式已并入状态区，这里只保留观测类指标。
    ///
    /// 四张卡，列数**只取 4 的因数**（4/2/1）。`.adaptive` 会在某些宽度下排出缺角的最后一行——
    /// 用户 2026-09-03 反馈的「首页有两个空的」正是那个。
    ///
    /// 从六张减到四张：内核内存与空山占用都是内存、合成一张；当前配置移进上方状态卡贴着节点。
    /// 会变的卡各自是独立视图（见文件头）；运行时长只读低频状态，留在这里。
    private var metrics: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: metricColumns),
            spacing: 12
        ) {
            ExitIPMetricBox()
            ConnectionsMetricBox()
            MemoryMetricBox()
            runtimeBox
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { updateMetricColumns(proxy.size.width) }
                    .onChange(of: proxy.size.width) { _, width in updateMetricColumns(width) }
            }
        }
    }

    private var runtimeBox: some View {
        MetricBox(symbol: "clock.arrow.2.circlepath", tint: .teal, caption: "运行时长") {
            RuntimeDurationLabel()
        }
    }

    private var activeConfig: AppState.ConfigItem? {
        state.configItems.first { $0.id == state.activeConfigID }
    }

    /// 只取 4 的因数，任何宽度下最后一行都排满。
    private func updateMetricColumns(_ width: CGFloat) {
        let candidates: [Int] = [4, 2]
        var next = 1
        for count in candidates {
            let needed: CGFloat = CGFloat(count) * 170 + CGFloat(count - 1) * 12
            if needed <= width {
                next = count
                break
            }
        }
        if next != metricColumns { metricColumns = next }
    }


    /// 「只跑内核」是测速拉起的临时状态：两个接管开关都是关的，但内核在计时。
    /// 不给出口的话，主窗口里没有任何办法停掉它（此前只在托盘有入口）。
    @ViewBuilder
    private var coreOnlyBanner: some View {
        if state.isOn, state.activeModes.isEmpty {
            HStack(spacing: 9) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                Text("内核正在运行但未接管网络（仅用于测速）。")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("停止内核") { Task { await state.stop() } }
                    .controlSize(.small)
                    .disabled(state.isBusy)
            }
            .padding(12)
            .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Color.blue.opacity(0.15), lineWidth: 0.5))
        }
    }

    /// 网络流量：标题行（范围切换 + 图例）、统计行、图表。
    ///
    /// 用户 2026-10-10 反馈这块「看起来一点用都没有」：原来只在仪表盘开着时才攒点、最多四分钟，
    /// 每次打开都从空白开始；上传、下载两块面积叠在一起，也没有任何可读的数字。
    /// 现在：近 4 分钟 / 近 1 小时两档（后台一直在攒）；下载画在横轴上方、上传画在下方；
    /// 统计行给出该范围的峰值与均值；鼠标悬停显示那一刻的速率。
    private struct DashboardTrafficGroup: View {
        @State private var range: TrafficRange = .recent

        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("网络流量")
                            .font(.headline)
                        Spacer()
                        TrafficLegend()
                        Picker("范围", selection: $range) {
                            ForEach(TrafficRange.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .fixedSize()
                    }
                    TrafficStatsRow(range: range)
                    TrafficPlot(range: range)
                }
                .padding(4)
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

/// 图表用的统一数据点：近 4 分钟是四秒一个的瞬时速率，近 1 小时是每分钟的均值（附峰值）。
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
            legend(symbol: "arrow.down", color: .green, title: "下载")
            legend(symbol: "arrow.up", color: .blue, title: "上传")
        }
    }

    private func legend(symbol: String, color: Color, title: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 统计行：本次会话累计 + 所选范围的峰值与均值。
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
            stat(title: "本次会话", value: Theme.bytesOrDash(state.sessionTotal),
                 detail: "↓ \(Theme.bytesOrDash(state.sessionDownload))  ↑ \(Theme.bytesOrDash(state.sessionUpload))")
            Divider().frame(height: 34).padding(.horizontal, 14)
            stat(title: "峰值", value: "↓ \(Theme.rateOrDash(downPeak))", detail: "↑ \(Theme.rateOrDash(upPeak))")
            Divider().frame(height: 34).padding(.horizontal, 14)
            stat(title: "均值", value: "↓ \(Theme.rateOrDash(downAverage))", detail: "↑ \(Theme.rateOrDash(upAverage))")
            Spacer(minLength: 0)
        }
    }

    private func stat(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
            Text(detail)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// 下载在横轴上方、上传在下方：两条曲线不再叠成一团，量级差很多时也都看得见形状。
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
                .foregroundStyle(.green.opacity(0.22))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("速率", point.download),
                    series: .value("方向", "下载线")
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("时间", point.time),
                    y: .value("速率", -point.upload),
                    series: .value("方向", "上传")
                )
                .foregroundStyle(.blue.opacity(0.2))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", point.time),
                    y: .value("速率", -point.upload),
                    series: .value("方向", "上传线")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
            if !points.isEmpty {
                RuleMark(y: .value("零", 0))
                    .foregroundStyle(.secondary.opacity(0.5))
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) {
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        .frame(height: 190)
        .transaction { transaction in transaction.animation = nil }
        .overlay {
            if points.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text(emptyText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyText: String {
        guard state.isOn else { return "开启代理后显示实时速率" }
        return range == .hour ? "每分钟记一个点，稍等一分钟" : "等待内核推送流量数据"
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 会变的小块

/// 上传 / 下载速率。每两秒一变，**单独成视图**：Observation 只失效这一小块，
/// 不再把整页（状态区、六张指标卡、图表容器）一起重排。
struct DashboardLiveRatePair: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let _ = Self.noteBodyEvaluation()
        HStack(spacing: 20) {
            rate(symbol: "arrow.up", tint: .blue, title: "上传", value: state.uploadRate)
            rate(symbol: "arrow.down", tint: .green, title: "下载", value: state.downloadRate)
        }
    }

    private func rate(symbol: String, tint: Color, title: String, value: Int64) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // 高频数值不做动画：.smooth 弹簧在下一次采样到来时仍未收敛，SwiftUI 会按
                // 屏幕刷新率持续插值字形——真机上曾以 ~57% CPU 连烧 8 小时（2026-08-20）。
                // monospacedDigit 已保证宽度稳定，数字直接跳变即可。
                // 不用 minimumScaleFactor：它在布局时要二分搜索字号，而这个值每秒都在变。
                Text(Theme.rateOrDash(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, alignment: .leading)
    }
}

private struct ExitIPMetricBox: View {
    @Environment(AppState.self) private var state

    var body: some View {
        MetricBox(symbol: "globe.asia.australia", tint: .orange, caption: "当前出口 IP") {
            value
        } corner: {
            HStack(spacing: 7) {
                if let error = state.exitDiagnosticsError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }
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
                    .help("刷新出口 IP 并检测 DNS")
                }
            }
        }
    }

    @ViewBuilder
    private var value: some View {
        if let report = state.exitDiagnostics {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.exit.ip)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(state.exitDiagnosticsIsStale ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                    if state.exitDiagnosticsIsStale {
                        // 切换节点后还没测到新出口：这个 IP 是切换前的，别让人当成新节点的。
                        Text("切换前")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.15)))
                            .help("已切换节点，正在探测新出口")
                    }
                }
                let locationOrg = [report.exit.location, report.exit.organization]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                Text(locationOrg.isEmpty ? "—" : locationOrg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 5) {
                    Circle()
                        .fill(dnsStatusTint(report.dns.status))
                        .frame(width: 6, height: 6)
                    Text(dnsStatusTitle(report.dns.status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(dnsStatusTint(report.dns.status))
                }
                .help(report.dns.detail)
                // 风险与 IP 类型：这一行直接回答"这个出口会不会被目标站点为难"。
                // 机房 IP + 中高风险，基本就是 Cloudflare 挑战的前兆。
                if let reputation = report.reputation, let risk = reputation.risk {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.riskTint(risk))
                            .frame(width: 6, height: 6)
                        Text(Theme.riskSummary(reputation))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.riskTint(risk))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help("出口 IP 风险评估，数据来自 \(IPReputationService.sourceName)")
                }
            }
        } else {
            Text(state.isRefreshingExitDiagnostics ? "检测中…" : (state.exitDiagnosticsError == nil ? "待检测" : "获取失败"))
                .font(.callout.weight(.medium))
                .foregroundStyle(state.exitDiagnosticsError == nil ? Color.secondary : Color.orange)
                .help(state.exitDiagnosticsError ?? "")
        }
    }

    private func dnsStatusTitle(_ status: DNSLeakStatus) -> String {
        switch status {
        case .clear: "DNS 未发现明显泄漏"
        case .possible: "DNS 可能泄漏"
        case .indeterminate: "DNS 无法判断"
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

private struct ConnectionsMetricBox: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // 高频数值不做动画（见 DashboardLiveRatePair 的说明）。
        MetricBox(symbol: "point.3.connected.trianglepath.dotted", tint: .purple, caption: "活跃连接") {
            Text("\(state.activeConnectionCount)")
        }
    }
}

/// 内核与 App 自身的内存合成一张卡：两者都是"占了多少内存"，分成两张既占位置又要用户自己对照。
/// 顺序固定为「内核 / 空山」，与 caption 一致。
private struct MemoryMetricBox: View {
    @Environment(AppState.self) private var state

    var body: some View {
        MetricBox(symbol: "memorychip", tint: .pink, caption: "内存（内核 / 空山）") {
            Text(text)
        } corner: {
            if let metrics = state.lastMetrics {
                // 空山自身的 CPU。放在角上而不是正文：它和内存不是一回事，但同属"本机开销"。
                Text(String(format: "%.1f%%", metrics.cpu))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("空山自身 CPU 占用，每分钟更新一次")
            }
        }
        .help(helpText)
    }

    private var text: String {
        let core = Theme.bytesOrDash(Int64(clamping: state.coreMemory))
        let app = state.lastMetrics.map { "\($0.rss) MB" } ?? "—"
        return "\(core) / \(app)"
    }

    private var helpText: String {
        // 内核的 /version 返回的就带名字（`sing-box 1.13.14`），不要再加「内核」前缀。
        let version = state.coreVersion == "—" ? "" : "；内核版本 \(state.coreVersion)"
        return "左：sing-box 内核占用（实时）。右：空山自身占用（每分钟更新）\(version)"
    }
}

/// 运行时长。
///
/// **不用 `Text(_:style:.timer)`**：那是每秒自更新的，而它嵌在指标网格里，
/// 每次刷新都会把整个 `GroupBox` 网格重新布局一遍。真机 2026-09-03 采样显示主线程
/// 持续耗在 `NSHostingView.layout` 与 `GraphHost.flushTransactions` 上，仪表盘开着时
/// 4~10% CPU，而同期数据刷新只有每分钟 15 次——不是数据驱动，是这类每秒失效。
/// 运行时长看到分钟就够，改为 `TimelineView(.everyMinute)`，刷新降到 1/60。
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

/// 指标块：`GroupBox` 承载，左上角系统符号 + 说明，紧接着是大号数值，多余高度留在底部。
/// 此前数值贴在卡片底边、说明贴顶边，中间一大段空白，六张卡看着像没加载完。
/// 图标是普通符号而不是渐变贴纸——系统设置里的分区图标也只是单色符号。
private struct MetricBox<Value: View, Corner: View>: View {
    let symbol: String
    let tint: Color
    let caption: String
    @ViewBuilder let value: Value
    @ViewBuilder let corner: Corner

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Label {
                        Text(caption)
                    } icon: {
                        Image(systemName: symbol)
                            .foregroundStyle(tint)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    corner
                }

                // 活跃连接与内核内存每秒都在变，minimumScaleFactor 会让每次变化
                // 都触发一次字号二分搜索。改为超长直接中间截断。
                value
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text(caption))

                Spacer(minLength: 0)
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        }
    }
}

extension MetricBox where Corner == EmptyView {
    init(
        symbol: String,
        tint: Color,
        caption: String,
        @ViewBuilder value: () -> Value
    ) {
        self.init(symbol: symbol, tint: tint, caption: caption, value: value) { EmptyView() }
    }
}

// MARK: - body 求值计数（测试用）

#if DEBUG
extension DashboardView {
    /// 整页 body 的求值次数。速率、连接数这类每秒变化的值**不该**让它涨——
    /// 涨了就是有高频状态又被读回了整页作用域。
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

/// 当前节点的延迟。只有它观察 `delays`。
private struct SelectedNodeDelayLabel: View {
    @Environment(AppState.self) private var state
    let nodeID: UUID

    var body: some View {
        if let delay = state.delays[nodeID] {
            DelayLabel(milliseconds: delay)
        }
    }
}
