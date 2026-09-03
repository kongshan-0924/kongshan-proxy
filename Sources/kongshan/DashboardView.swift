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
                    ContentUnavailableView(
                        "还没有节点",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("请在“配置”页导入 Clash 订阅或添加手动 Hysteria2。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            .padding(20)
        }
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

    private var statusGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 14) {
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
                        if let selected = state.selectedNode {
                            HStack(spacing: 6) {
                                Text(selected.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                ProtocolTag(value: selected.protocolType)
                                if let delay = state.delays[selected.id] {
                                    DelayLabel(milliseconds: delay)
                                }
                            }
                        } else {
                            Text("未启用或未选择节点")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    DashboardLiveRatePair()
                }

                Divider()

                HStack(spacing: 14) {
                    Picker("出站模式", selection: outboundModeBinding) {
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
        }
    }

    private func modeToggle(title: String, mode: ProxyMode) -> some View {
        Toggle(title, isOn: modeBinding(mode))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(state.isBusy || !state.isReady)
    }

    private func modeBinding(_ mode: ProxyMode) -> Binding<Bool> {
        Binding(
            get: { state.activeModes.contains(mode) },
            set: { enabled in Task { await state.setMode(mode, enabled: enabled) } }
        )
    }

    // MARK: - 指标

    /// 接管方式、当前节点与出站模式已并入状态区，这里只保留观测类指标。
    ///
    /// 六张卡，列数**只取 6 的因数**（6/3/2/1）。`.adaptive` 会在某些宽度下排成 4 或 5 列，
    /// 最后一行就缺两个角——用户反馈的「首页有两个空的」正是这个。
    ///
    /// 会变的卡各自是独立视图（见文件头）；运行时长与当前配置只读低频状态，留在这里。
    private var metrics: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: metricColumns),
            spacing: 12
        ) {
            ExitIPMetricBox()
            ConnectionsMetricBox()
            CoreMemoryMetricBox()
            runtimeBox
            activeConfigBox
            SelfUsageMetricBox()
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

    private var activeConfigBox: some View {
        MetricBox(symbol: "doc.badge.gearshape", tint: .indigo, caption: "当前配置") {
            Text(activeConfig?.name ?? "无")
        } corner: {
            if let config = activeConfig {
                Text("\(config.nodeCount) 个节点")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activeConfig: AppState.ConfigItem? {
        state.configItems.first { $0.id == state.activeConfigID }
    }

    /// 只取 6 的因数，任何宽度下最后一行都排满。
    private func updateMetricColumns(_ width: CGFloat) {
        let candidates: [Int] = [6, 3, 2]
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

    private var outboundModeBinding: Binding<OutboundMode> {
        Binding(
            get: { state.outboundMode },
            set: { mode in Task { await state.setOutboundMode(mode) } }
        )
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
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// 三块各自跟踪 Observation：速率每秒变，只更新标题；累计量和图表互不牵连。
    private struct DashboardTrafficGroup: View {
        var body: some View {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    TrafficHeader()
                    SessionTrafficRow()
                    TrafficPlot()
                }
                .padding(4)
            }
        }
    }

    private struct TrafficHeader: View {
        var body: some View {
            HStack(alignment: .center) {
                Text("网络流量")
                    .font(.headline)
                Spacer()
                HStack(spacing: 12) {
                    legendDot(color: .blue, title: "上传")
                    legendDot(color: .green, title: "下载")
                }
            }
        }

        private func legendDot(color: Color, title: String) -> some View {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 本次会话累计流量。数据来自内核权威累计计数器，跨内核重启连续。
    private struct SessionTrafficRow: View {
        @Environment(AppState.self) private var state

        var body: some View {
            HStack(spacing: 10) {
                Text("本次会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Theme.bytesOrDash(state.sessionTotal))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .accessibilityLabel("本次会话共 \(Theme.bytesOrDash(state.sessionTotal))")
                Divider().frame(height: 11)
                sessionLeg(symbol: "arrow.up", tint: .blue, value: state.sessionUpload)
                sessionLeg(symbol: "arrow.down", tint: .green, value: state.sessionDownload)
                Spacer(minLength: 0)
            }
        }

        private func sessionLeg(symbol: String, tint: Color, value: Int64) -> some View {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(Theme.bytesOrDash(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct TrafficPlot: View {
        @Environment(AppState.self) private var state

        var body: some View {
            Chart {
                ForEach(state.trafficHistory) { point in
                    AreaMark(
                        x: .value("时间", point.timestamp),
                        y: .value("速率", point.download),
                        series: .value("方向", "下载")
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.green.opacity(0.3), .green.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.linear)

                    AreaMark(
                        x: .value("时间", point.timestamp),
                        y: .value("速率", point.upload),
                        series: .value("方向", "上传")
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [.blue.opacity(0.26), .blue.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("速率", point.download),
                        series: .value("方向", "下载线")
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.linear)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("速率", point.upload),
                        series: .value("方向", "上传线")
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.linear)
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let bytes = value.as(Int64.self) {
                            Text(bytes == 0 ? "0" : Theme.bytes(bytes))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 170)
            .transaction { transaction in transaction.animation = nil }
            .overlay {
                if state.trafficHistory.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text(state.isOn ? "等待内核推送流量数据" : "开启代理后显示实时速率")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
                Text(report.exit.ip)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .textSelection(.enabled)
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

private struct CoreMemoryMetricBox: View {
    @Environment(AppState.self) private var state

    var body: some View {
        MetricBox(symbol: "memorychip", tint: .pink, caption: "内核内存") {
            Text(Theme.bytesOrDash(Int64(clamping: state.coreMemory)))
        } corner: {
            if state.coreVersion != "—" {
                // 内核的 /version 返回的就带名字（`sing-box 1.13.14`），
                // 不要再加「内核」前缀——真机上会读成「内核 sing-box 1.13.14」。
                Text(state.coreVersion)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("内置 sing-box 版本")
            }
        }
    }
}

/// 空山自身的占用。与「内核内存」是两回事（那是 sing-box），标签已写明。
/// 数据来自每分钟一次的运行指标，不额外采样。
private struct SelfUsageMetricBox: View {
    @Environment(AppState.self) private var state

    var body: some View {
        MetricBox(symbol: "cpu", tint: .brown, caption: "空山占用") {
            if let metrics = state.lastMetrics {
                Text(String(format: "%.1f%%", metrics.cpu))
            } else {
                Text("—")
            }
        } corner: {
            if let metrics = state.lastMetrics {
                Text("\(metrics.rss) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("内存占用，每分钟更新一次")
            }
        }
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
