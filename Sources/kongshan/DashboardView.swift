import Charts
import KongshanCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
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

                    HStack(spacing: 20) {
                        rate(symbol: "arrow.up", tint: .blue, title: "上传", value: state.uploadRate)
                        rate(symbol: "arrow.down", tint: .green, title: "下载", value: state.downloadRate)
                    }
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
                Text(Theme.rateOrDash(value))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, alignment: .leading)
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
    private var metrics: some View {
        // 自适应列数：窗口拉宽时 4 列，拖窄时自动收成 3/2 列。
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
            spacing: 12
        ) {
            MetricBox(symbol: "globe.asia.australia", tint: .orange, caption: "当前出口 IP") {
                exitDiagnosticsValue
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

            MetricBox(symbol: "point.3.connected.trianglepath.dotted", tint: .purple, caption: "活跃连接") {
                // 同上：高频数值不做动画（见 rate 的说明）。
                Text("\(state.activeConnectionCount)")
            }

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

            MetricBox(symbol: "clock.arrow.2.circlepath", tint: .teal, caption: "运行时长") {
                if state.isOn, let startedAt = state.runtimeStartedAt {
                    Text(startedAt, style: .timer)
                } else {
                    Text("—")
                }
            }
        }
    }

    private var outboundModeBinding: Binding<OutboundMode> {
        Binding(
            get: { state.outboundMode },
            set: { mode in Task { await state.setOutboundMode(mode) } }
        )
    }

    @ViewBuilder
    private var exitDiagnosticsValue: some View {
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

    // MARK: - 速率曲线

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
        @Environment(AppState.self) private var state

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
                    .interpolationMethod(.monotone)

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
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("速率", point.download),
                        series: .value("方向", "下载线")
                    )
                    .foregroundStyle(.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("速率", point.upload),
                        series: .value("方向", "上传线")
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .interpolationMethod(.monotone)
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
}

/// 指标块：`GroupBox` 承载，左上角系统符号 + 说明，下方大号数值。
/// 图标是普通符号而不是渐变贴纸——系统设置里的分区图标也只是单色符号。
private struct MetricBox<Value: View, Corner: View>: View {
    let symbol: String
    let tint: Color
    let caption: String
    @ViewBuilder let value: Value
    @ViewBuilder let corner: Corner

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
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

                Spacer(minLength: 12)

                value
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .truncationMode(.middle)
                    .accessibilityLabel(Text(caption))
            }
            .padding(4)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
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
