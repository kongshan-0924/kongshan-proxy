import Charts
import KongshanCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "仪表盘", subtitle: nil) {
                HStack(spacing: 8) {
                    Picker("出站模式", selection: outboundModeBinding) {
                        ForEach(OutboundMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 180)
                    .help(state.outboundMode.detail)
                    .disabled(state.isBusy || !state.isReady)

                    ModePill(
                        title: ProxyMode.systemProxy.displayName,
                        isActive: state.activeModes.contains(.systemProxy),
                        isBusy: state.isBusy || !state.isReady
                    ) {
                        toggle(.systemProxy)
                    }
                    ModePill(
                        title: ProxyMode.tun.displayName,
                        isActive: state.activeModes.contains(.tun),
                        isBusy: state.isBusy || !state.isReady
                    ) {
                        toggle(.tun)
                    }
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    coreOnlyBanner
                    metrics
                    trafficChart

                    if state.nodes.isEmpty {
                        ContentUnavailableView(
                            "还没有节点",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("请在“节点”页导入 Clash 订阅或添加手动 Hysteria2。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 150)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .pageBackground()
        .navigationTitle("仪表盘")
        .onAppear { state.startDashboardMonitoring() }
        .onDisappear { state.stopDashboardMonitoring() }
    }

    // MARK: - 指标卡

    private var metrics: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
            spacing: 14
        ) {
            MetricCard(symbol: "shield.lefthalf.filled", tint: .blue, caption: "接管方式") {
                Text(activeModesText)
            } corner: {
                StatusBadge(text: "出站 · \(state.outboundMode.displayName)", tint: state.statusTint)
            }

            MetricCard(symbol: "point.3.connected.trianglepath.dotted", tint: .green, caption: "当前节点") {
                Text(state.selectedNode?.name ?? "未选择")
            } corner: {
                if let node = state.selectedNode {
                    ProtocolTag(value: node.protocolType)
                }
            }

            MetricCard(symbol: "bolt.horizontal", tint: .orange, caption: "出口连通性") {
                connectivityValue
            } corner: {
                if state.isProbingConnectivity {
                    ProgressView().controlSize(.small)
                } else if state.isOn {
                    Button {
                        Task { await state.probeConnectivity() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("重新测试")
                }
            }

            MetricCard(symbol: "link", tint: .purple, caption: "活跃连接") {
                Text("\(state.activeConnectionCount)")
            }

            MetricCard(symbol: "memorychip", tint: .pink, caption: "内核内存") {
                Text(Theme.bytes(Int64(clamping: state.coreMemory)))
            } corner: {
                if state.coreVersion != "—" {
                    Text(state.coreVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var activeModesText: String {
        let ordered: [ProxyMode] = [.systemProxy, .tun]
        let names = ordered.filter(state.activeModes.contains).map(\.displayName)
        return names.isEmpty ? "未开启" : names.joined(separator: " + ")
    }

    /// 开启接管后经当前节点实测到 Google / GitHub 的往返延迟。
    @ViewBuilder
    private var connectivityValue: some View {
        if !state.isOn {
            Text("—")
        } else if state.connectivity.isEmpty {
            Text(state.isProbingConnectivity ? "测试中…" : "待测试")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(AppState.connectivityTargets, id: \.name) { target in
                    HStack(spacing: 6) {
                        Text(target.name)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .leading)
                        connectivityReading(state.connectivity[target.name])
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func connectivityReading(_ value: Int??) -> some View {
        switch value {
        case let .some(.some(milliseconds)):
            Text("\(milliseconds) ms")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.delayColor(milliseconds))
        case .some(.none):
            Text("不可达")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.red)
        case .none:
            Text("—")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 速率曲线

    private var trafficChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("网络流量")
                        .font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 12) {
                        legendDot(color: .blue, title: "上传")
                        legendDot(color: .green, title: "下载")
                    }
                }
                Spacer()
                HStack(spacing: 18) {
                    rateSummary(symbol: "arrow.up", tint: .blue, value: state.uploadRate, title: "上传")
                    rateSummary(symbol: "arrow.down", tint: .green, value: state.downloadRate, title: "下载")
                }
            }

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
                            Text(Theme.bytes(bytes))
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
            // 固定高度：占位视图放在 overlay 里，用 minHeight 会被撑到几百点高。
            .frame(height: 200)
            // 每秒推送一次，禁用隐式动画避免持续重绘带来的 CPU 占用。
            .transaction { transaction in
                transaction.animation = nil
            }
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
        .card(padding: 18)
    }

    private func rateSummary(symbol: String, tint: Color, value: Int64, title: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(Theme.rate(value))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

    /// 「只跑内核」是测速拉起的临时状态：两个接管胶囊都是灰的，但内核在计时。
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

    /// 胶囊点击：独立开关该接管方式，两者可同时生效。
    private func toggle(_ mode: ProxyMode) {
        Task { await state.setMode(mode, enabled: !state.activeModes.contains(mode)) }
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
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .card(padding: 16)
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
