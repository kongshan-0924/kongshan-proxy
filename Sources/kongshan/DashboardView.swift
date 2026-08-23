import Charts
import KongshanCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "仪表盘", subtitle: "系统状态与实时网络流量监控")

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    heroControlCard
                    coreOnlyBanner
                    metrics
                    DashboardTrafficCard()

                    if state.nodes.isEmpty {
                        ContentUnavailableView(
                            "还没有节点",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("请在“配置”页导入 Clash 订阅或添加手动 Hysteria2。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
        }
        .pageBackground()
        .navigationTitle("仪表盘")
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

    // MARK: - Hero 控制面板

    private var heroControlCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.statusTint)
                            .frame(width: 9, height: 9)
                            .shadow(
                                color: state.statusTint.opacity(state.isOn ? 0.55 : 0),
                                radius: 3
                            )
                        Text(state.statusText)
                            .font(.system(size: 16, weight: .bold))
                        if state.isOn {
                            StatusBadge(text: "出站 · \(state.outboundMode.displayName)", tint: state.statusTint)
                        }
                    }
                    if let selected = state.selectedNode {
                        HStack(spacing: 6) {
                            Text(selected.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            ProtocolTag(value: selected.protocolType)
                            if let delay = state.delays[selected.id] {
                                DelayLabel(milliseconds: delay)
                            }
                        }
                    } else {
                        Text("未启用或未选择节点")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // 实时速率并入 Hero：原来单独的「网络流量」卡标题行不再重复占用一层。
                HStack(spacing: 16) {
                    heroRate(symbol: "arrow.up", tint: .blue, title: "上传", value: state.uploadRate)
                    heroRate(symbol: "arrow.down", tint: .green, title: "下载", value: state.downloadRate)
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
                // 弹性宽度：窄窗口下让位给开关与断开按钮，宽窗口下最多 240。
                .frame(minWidth: 150, maxWidth: 240)
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
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red.opacity(0.85))
                    .controlSize(.small)
                    .disabled(state.isBusy)
                }
            }
        }
        .card()
    }

    private func heroRate(symbol: String, tint: Color, title: String, value: Int64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                // 高频数值不做动画：.smooth 弹簧在下一次采样到来时仍未收敛，SwiftUI 会按
                // 屏幕刷新率持续插值字形——真机上曾以 ~57% CPU 连烧 8 小时（2026-08-20）。
                // monospacedDigit 已保证宽度稳定，数字直接跳变即可。
                Text(Theme.rateOrDash(value))
                    .font(.system(size: 18, weight: .bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 108, alignment: .leading)
    }

    private func modeToggle(title: String, mode: ProxyMode) -> some View {
        Toggle(title, isOn: modeBinding(mode))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12, weight: .medium))
            .disabled(state.isBusy || !state.isReady)
    }

    private func modeBinding(_ mode: ProxyMode) -> Binding<Bool> {
        Binding(
            get: { state.activeModes.contains(mode) },
            set: { enabled in Task { await state.setMode(mode, enabled: enabled) } }
        )
    }

    // MARK: - 指标卡

    /// 接管方式、当前节点与出站模式已并入 Hero 卡，这里只保留观测类指标。
    private var metrics: some View {
        // 自适应列数：窗口拉宽时 4 列，拖窄时自动收成 3/2 列，卡片不再被压扁。
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
            spacing: 10
        ) {
            MetricCard(symbol: "network", tint: .orange, caption: "当前出口 IP") {
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
                            Label("检测", systemImage: "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("刷新出口 IP 并检测 DNS")
                    }
                }
            }

            MetricCard(symbol: "link", tint: .purple, caption: "活跃连接") {
                // 同上：高频数值不做动画（见 heroRate 的说明）。
                Text("\(state.activeConnectionCount)")
            }

            MetricCard(symbol: "memorychip", tint: .pink, caption: "内核内存") {
                // 同上：高频数值不做动画（见 heroRate 的说明）。
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

            MetricCard(symbol: "clock", tint: .teal, caption: "运行时长") {
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
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
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
                .font(.system(size: 13, weight: .medium))
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
    private struct DashboardTrafficCard: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                TrafficHeader()
                SessionTrafficRow()
                TrafficPlot()
            }
            .card()
        }
    }

    private struct TrafficHeader: View {
        @Environment(AppState.self) private var state

        var body: some View {
            // 实时速率已上移到 Hero 卡，这里只保留图例，避免同一数据三处展示。
            HStack(alignment: .center) {
                Text("网络流量")
                    .font(.system(size: 15, weight: .semibold))
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
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("本次会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(Theme.bytesOrDash(state.sessionTotal))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .accessibilityLabel("本次会话共 \(Theme.bytesOrDash(state.sessionTotal))")

                Divider().frame(height: 11)
                sessionLeg(symbol: "arrow.up", tint: .blue, value: state.sessionUpload)
                sessionLeg(symbol: "arrow.down", tint: .green, value: state.sessionDownload)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.cardFill.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.subcardRadius, style: .continuous))
        }

        private func sessionLeg(symbol: String, tint: Color, value: Int64) -> some View {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
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
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(.blue.opacity(0.25), lineWidth: 0.5)
            )
        }
    }
}

/// Stash 风格指标卡：左上角彩色图标块，右上角可选角标，底部说明 + 大号数值。
private struct MetricCard<Value: View, Corner: View>: View {
    let symbol: String
    let tint: Color
    let caption: String
    @ViewBuilder let value: Value
    @ViewBuilder let corner: Corner

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                IconBadge(symbol: symbol, tint: tint)
                Spacer(minLength: 8)
                corner
            }

            Spacer(minLength: 14)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 3)

            value
                .font(.system(size: 19, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .truncationMode(.middle)
                .accessibilityLabel(Text(caption))
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .card()
    }
}

extension MetricCard where Corner == EmptyView {
    init(
        symbol: String,
        tint: Color,
        caption: String,
        @ViewBuilder value: () -> Value
    ) {
        self.init(symbol: symbol, tint: tint, caption: caption, value: value) { EmptyView() }
    }
}
