import Charts
import KongshanCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                proxyHeader
                proxyModeControl
                metrics
                trafficChart
                errorBanner

                if state.nodes.isEmpty {
                    ContentUnavailableView(
                        "还没有节点",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("请在“节点”页导入 Clash 订阅或添加手动 Hysteria2。")
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                }
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
        .onAppear { state.startDashboardMonitoring() }
        .onDisappear { state.stopDashboardMonitoring() }
    }

    private var proxyHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: state.menuBarSymbol)
                .font(.system(size: 42))
                .foregroundStyle(state.isOn ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.statusText)
                    .font(.title2.weight(.semibold))
                Text(state.selectedNode.map { "当前节点：\($0.name)" } ?? "尚未选择节点")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(state.activeMode != nil ? "关闭代理" : "开启\(modeTitle(state.preferredMode))") {
                Task {
                    if state.activeMode != nil {
                        await state.stop()
                    } else {
                        await state.startPreferredProxy()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isBusy || !state.isReady)
        }
    }

    private var proxyModeControl: some View {
        GroupBox("代理模式") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("首选接管方式", selection: modeBinding) {
                    Text("系统代理").tag(ProxyMode.systemProxy)
                    Text("TUN").tag(ProxyMode.tun)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(state.isBusy || !state.isReady)

                Text("TUN 模式的启动和停止需要管理员授权。在线切换会先完整关闭当前模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var metrics: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
            spacing: 12
        ) {
            DashboardMetricCard(
                title: "上传速率",
                value: rateText(state.uploadRate),
                symbol: "arrow.up",
                tint: .blue
            )
            DashboardMetricCard(
                title: "下载速率",
                value: rateText(state.downloadRate),
                symbol: "arrow.down",
                tint: .green
            )
            DashboardMetricCard(
                title: "活动连接",
                value: "\(state.activeConnectionCount)",
                symbol: "point.3.connected.trianglepath.dotted",
                tint: .orange
            )
            DashboardMetricCard(
                title: "内核内存",
                value: byteText(Int64(clamping: state.coreMemory)),
                symbol: "memorychip",
                tint: .purple
            )
            DashboardMetricCard(
                title: "内核版本",
                value: state.coreVersion,
                symbol: "shippingbox",
                tint: .indigo
            )
            DashboardMetricCard(
                title: "运行时长",
                value: uptimeText,
                symbol: "clock",
                tint: .teal
            )
        }
    }

    private var trafficChart: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("实时速率")
                        .font(.headline)
                    Spacer()
                    Text("最近 60 秒")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Chart {
                    ForEach(state.trafficHistory) { point in
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("速率", point.upload),
                            series: .value("方向", "上传")
                        )
                        .foregroundStyle(by: .value("方向", "上传"))
                        .interpolationMethod(.linear)

                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("速率", point.download),
                            series: .value("方向", "下载")
                        )
                        .foregroundStyle(by: .value("方向", "下载"))
                        .interpolationMethod(.linear)
                    }
                }
                .chartForegroundStyleScale([
                    "上传": Color.blue,
                    "下载": Color.green
                ])
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let bytes = value.as(Int64.self) {
                                Text(rateText(bytes))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.second())
                    }
                }
                .frame(minHeight: 210)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .overlay {
                    if state.trafficHistory.isEmpty {
                        ContentUnavailableView(
                            state.isOn ? "等待流量数据" : "代理未启动",
                            systemImage: "chart.xyaxis.line",
                            description: Text(state.isOn ? "内核正在建立推送。" : "开启代理后显示实时速率。")
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = state.errorMessage {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error).textSelection(.enabled)
                Spacer()
                Button("忽略") { state.dismissError() }
            }
            .padding(12)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { state.preferredMode },
            set: { mode in Task { await state.switchMode(to: mode) } }
        )
    }

    private var uptimeText: String {
        guard state.isOn, let startedAt = state.runtimeStartedAt else { return "—" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainder) }
        return String(format: "%02d:%02d", minutes, remainder)
    }

    private func modeTitle(_ mode: ProxyMode) -> String {
        mode == .tun ? "TUN" : "系统代理"
    }

    private func rateText(_ bytes: Int64) -> String {
        "\(byteText(bytes))/s"
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .memory)
    }
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .accessibilityLabel("\(title)\(value)")
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}
