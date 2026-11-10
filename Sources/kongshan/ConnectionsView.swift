import AppKit
import KongshanCore
import SwiftUI

/// 连接监控页：实时列出活跃连接（目标主机 / 进程、命中的规则与出站链路、上下行流量），
/// 支持单条关闭与工具栏一键全部关闭。只在本页可见时订阅，离开即停。
///
/// 顶部为活跃连接、实时速率、主要去向三个指标小窗；下方为主连接原生表格与出站链路详情小窗。
struct ConnectionsView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\ConnectionLiveDetail.totalRate, order: .reverse)]
    /// 列的显示与顺序由用户定，跨会话记住。两个「累计」列默认隐藏——
    /// 默认全开的话 7 列在 760pt 最小窗口下放不下，只能横向翻。
    /// 需要看累计量时右键表头勾出来即可。
    @AppStorage("connections.columns") private var columnCustomizationData = ""
    @State private var columnCustomization = TableColumnCustomization<ConnectionLiveDetail>()
    @State private var selection: Set<ConnectionLiveDetail.ID> = []
    @State private var confirmsCloseAll = false
    /// 局域网分段里没应用的草稿：切到「本机」再切回时接着改（离开连接页则不保留）。
    @State private var parkedLANDraft: LANSharingSettings?
    @Binding var scope: ConnectionsPageView.Tab

    init(scope: Binding<ConnectionsPageView.Tab> = .constant(.local)) {
        self._scope = scope
    }

    private var filteredConnections: [ConnectionLiveDetail] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = query.isEmpty ? state.connections : state.connections.filter { conn in
            conn.host.localizedCaseInsensitiveContains(query)
                || (conn.process?.localizedCaseInsensitiveContains(query) ?? false)
                || conn.rule.localizedCaseInsensitiveContains(query)
                || conn.chains.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
        return matched.sorted(using: sortOrder)
    }

    var body: some View {
        Group {
            // 局域网分段就是完整的共享页（开关、接入方式、端口与来源白名单、已接入设备，设备监控随它启停）。
            // 原型重排时曾换成只有开关和设备列表的简版，端口 / 白名单失去入口、设备列表也不再刷新（2026-11-09 审计）。
            if scope == .lan {
                SharingView(parkedDraft: $parkedLANDraft)
            } else {
                localBody
            }
        }
        .buttonStyle(.pill)
        .pageTopBar {
                CapsuleSegmentedPicker(options: ConnectionsPageView.Tab.allCases, selection: $scope) { $0.rawValue }
                    .fixedSize()
                Spacer(minLength: 8)
                if scope == .local {
                    closeAllButton
                }
        }
        .confirmationDialog(
            "关闭全部 \(state.connections.count) 条活跃连接？",
            isPresented: $confirmsCloseAll,
            titleVisibility: .visible
        ) {
            Button("全部关闭", role: .destructive) {
                Task { await state.closeAllActiveConnections() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("进行中的下载和长连接会立即断开，应用通常会自行重连。")
        }
    }

    private var closeAllButton: some View {
        Button(role: .destructive) {
            confirmsCloseAll = true
        } label: {
            Label {
                Text("全部关闭")
            } icon: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(state.connections.isEmpty ? Theme.textTertiary : Theme.danger.icon)
            }
            .frame(minWidth: 24, minHeight: 24)
        }
        .disabled(state.connections.isEmpty)
        .accessibilityLabel("关闭全部活跃连接")
        .help("关闭全部活跃连接")
    }

    /// 本机分段：连接监控只在它出现时运行，切到局域网分段即停。
    private var localBody: some View {
        let list = filteredConnections
        let nodeNames = state.outboundTagToNodeName

        return VStack(alignment: .leading, spacing: Theme.cardGap) {
            HStack(spacing: Theme.cardGap) {
                ActiveConnectionsTile()
                LiveSpeedTile()
                TopDestinationsTile()
            }
            .frame(height: 96)

            bottomArea(list: list, nodeNames: nodeNames)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvasBackground)
        // 原型取消了页面级底栏，原 PageStatusBar(subtitle) 的统计信息已并入连接卡片标题行右侧
        .onAppear {
            state.startConnectionsMonitoring()
            restoreColumnCustomization()
        }
        .onChange(of: columnCustomization) { _, new in
            if let data = try? JSONEncoder().encode(new) {
                columnCustomizationData = String(decoding: data, as: UTF8.self)
            }
        }
        .onDisappear { state.stopConnectionsMonitoring() }
    }

    private func restoreColumnCustomization() {
        guard !columnCustomizationData.isEmpty,
              let stored = try? JSONDecoder().decode(
                  TableColumnCustomization<ConnectionLiveDetail>.self,
                  from: Data(columnCustomizationData.utf8)
              ) else { return }
        columnCustomization = stored
    }

    // MARK: - 下方表格卡与详情小窗

    @ViewBuilder
    private func bottomArea(list: [ConnectionLiveDetail], nodeNames: [String: String]) -> some View {
        let hasConnections = !state.connections.isEmpty && state.status == .on
        if !hasConnections {
            tableCard(list: list, nodeNames: nodeNames, fillsHeight: false)
        } else {
            GeometryReader { geo in
                let isWide = geo.size.width >= 820
                let selectedConn = list.first { selection.contains($0.id) }

                if let selectedConn {
                    if isWide {
                        HStack(alignment: .top, spacing: Theme.cardGap) {
                            tableCard(list: list, nodeNames: nodeNames, fillsHeight: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            connectionDetailTile(selectedConn, nodeNames: nodeNames, height: 320)
                                .frame(width: 280)
                        }
                    } else {
                        VStack(spacing: Theme.cardGap) {
                            tableCard(list: list, nodeNames: nodeNames, fillsHeight: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            connectionDetailTile(selectedConn, nodeNames: nodeNames, height: 180)
                        }
                    }
                } else {
                    tableCard(list: list, nodeNames: nodeNames, fillsHeight: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func tableCard(list: [ConnectionLiveDetail], nodeNames: [String: String], fillsHeight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("连接")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(list.count) 条")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                // 原型：搜索在连接表卡标题行（⌘F 聚焦、Esc 清空）。
                TopBarSearchField(text: $searchText, prompt: "搜索目标、进程或规则")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Theme.separator.frame(height: 0.5)

            if state.status != .on || state.connections.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.textTertiary)
                    Text("暂无活跃连接")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text("开启系统代理或 TUN 后，经过 kongshan 的连接会显示在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else if list.isEmpty {
                TileEmptyNote(text: "未找到匹配“\(searchText)”的连接")
                    .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
            } else {
                table(list, nodeNames: nodeNames)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func connectionDetailTile(_ conn: ConnectionLiveDetail, nodeNames: [String: String], height: CGFloat) -> some View {
        TileCard(
            "出站链路",
            symbol: "point.3.connected.trianglepath.dotted",
            detail: conn.network.uppercased(),
            height: height,
            trailing: {
                Button {
                    selection.removeAll()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.pill)
                .controlSize(.small)
                .accessibilityLabel("关闭详情")
                .help("关闭详情")
            },
            content: {
                TileRow(symbol: "globe", "目标", subtitle: conn.host, subtitleMonospaced: true, showsDivider: true) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(conn.host, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.pill)
                    .controlSize(.small)
                    .accessibilityLabel("拷贝目标地址")
                    .help("拷贝目标地址")
                }

                if conn.connection.viaLocalProxyEntry {
                    TileRow(symbol: "shield", "来源", subtitle: "经系统代理（进程未识别）", showsDivider: true)
                } else if let process = conn.process, !process.isEmpty {
                    TileRow(symbol: "app", "进程", subtitle: process, showsDivider: true)
                }

                TileRow(
                    symbol: "arrow.triangle.branch",
                    "命中规则",
                    subtitle: conn.rule.isEmpty ? "未报告" : conn.rule,
                    subtitleMonospaced: !conn.rule.isEmpty, showsDivider: true
                )

                ForEach(Array(conn.chains.enumerated()), id: \.offset) { index, tag in
                    let name = nodeNames[tag] ?? tag
                    TileRow(
                        symbol: "\(index + 1).circle",
                        name,
                        subtitle: name != tag ? tag : nil, subtitleMonospaced: true, showsDivider: true
                    )
                }

                TileRow(
                    symbol: "speedometer",
                    "速率",
                    subtitle: "↑ \(Theme.rateOrDash(conn.uploadRate)) · ↓ \(Theme.rateOrDash(conn.downloadRate))",
                    subtitleMonospaced: true, showsDivider: true
                )

                TileRow(
                    symbol: "internaldrive",
                    "累计",
                    subtitle: "↑ \(Theme.bytesOrDash(conn.upload)) · ↓ \(Theme.bytesOrDash(conn.download))",
                    subtitleMonospaced: true,
                    showsDivider: false
                )
            }
        )
    }

    private func table(_ list: [ConnectionLiveDetail], nodeNames: [String: String]) -> some View {
        Table(list, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("进程", value: \.processSortKey) { conn in
                Text(conn.connection.viaLocalProxyEntry ? "系统代理" : (conn.process ?? "未知"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 80, ideal: 120)
            .customizationID("process")

            TableColumn("目标", value: \.host) { conn in
                Text(conn.host)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 140, ideal: 220)
            .customizationID("host")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("策略 / 规则", value: \.rule) { conn in
                let text = chainText(conn, nodeNames: nodeNames)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(text)
            }
            .width(min: 110, ideal: 180)
            .customizationID("rule")

            TableColumn("网络", value: \.network) { conn in
                Text(conn.network.uppercased())
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .width(min: 50, ideal: 60)
            .customizationID("network")

            TableColumn("下行", value: \.downloadRate) { conn in
                rateCell(conn.downloadRate, active: conn.totalRate > 0)
            }
            .width(min: 60, ideal: 80)
            .customizationID("downloadRate")

            TableColumn("时间", value: \.startSortKey) { conn in
                Text(conn.connection.start.map(formatDuration) ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .width(min: 50, ideal: 70)
            .customizationID("time")

            TableColumn("↑ 累计", value: \.upload) { conn in
                Text(Theme.bytesOrDash(conn.upload))
                    .font(.callout.monospacedDigit())
            }
            .width(min: 64, ideal: 76)
            .customizationID("upload")
            .defaultVisibility(.hidden)

            TableColumn("↓ 累计", value: \.download) { conn in
                Text(Theme.bytesOrDash(conn.download))
                    .font(.callout.monospacedDigit())
            }
            .width(min: 64, ideal: 76)
            .customizationID("download")
            .defaultVisibility(.hidden)

            TableColumn("") { conn in
                Button(role: .destructive) {
                    Task { await state.closeConnection(conn.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(selection.contains(conn.id) ? AnyShapeStyle(.primary) : AnyShapeStyle(Theme.danger.icon))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("关闭此连接")
                .accessibilityLabel("关闭 \(conn.host)")
            }
            .width(28)
            .customizationID("close")
            .disabledCustomizationBehavior(.all)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: ConnectionLiveDetail.ID.self) { ids in
            contextMenu(for: ids, in: list)
        } primaryAction: { ids in
            selection = ids
        }
    }

    private func rateCell(_ value: Int64, active: Bool) -> some View {
        Text(Theme.rateOrDash(value))
            .font(.system(size: 12).monospacedDigit())
            .fontWeight(active ? .medium : .regular)
    }

    private func formatDuration(_ startTime: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(startTime)))
        if seconds < 60 {
            return "\(seconds) 秒"
        } else if seconds < 3600 {
            return "\(seconds / 60) 分钟"
        } else {
            return "\(seconds / 3600) 小时"
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<ConnectionLiveDetail.ID>, in list: [ConnectionLiveDetail]) -> some View {
        if ids.count == 1, let id = ids.first, let conn = list.first(where: { $0.id == id }) {
            let endpoint = ConnectionEndpoint(hostAndPort: conn.host)
            Button {
                Task {
                    _ = await state.upsertForcedProxyRule(
                        type: endpoint.isIPAddress ? .ipCIDR : .domainSuffix,
                        value: endpoint.address
                    )
                }
            } label: {
                Label("强制走代理", systemImage: "arrow.up.forward.app")
            }
            Button {
                Task {
                    _ = await state.upsertDirectRule(
                        type: endpoint.isIPAddress ? .ipCIDR : .domainSuffix,
                        value: endpoint.address
                    )
                }
            } label: {
                Label("始终直连", systemImage: "arrow.right.circle")
            }
            if let process = conn.process, !process.isEmpty, !conn.connection.viaLocalProxyEntry {
                Button {
                    Task {
                        await state.upsertProcessRule(
                            processName: process,
                            action: .proxy,
                            proxyTarget: state.primaryGroupName ?? "手动选择"
                        )
                    }
                } label: {
                    Label("按该 App 分流", systemImage: "app.badge.checkmark")
                }
            }
            Divider()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(endpoint.displayValue, forType: .string)
            } label: {
                Label("复制域名或 IP", systemImage: "doc.on.doc")
            }
            Button {
                selection = [conn.id]
            } label: {
                Label("查看完整命中链路", systemImage: "point.3.connected.trianglepath.dotted")
            }
            Divider()
            Button(role: .destructive) {
                Task { await state.closeConnection(conn.id) }
            } label: {
                Label("关闭此连接", systemImage: "xmark.circle")
            }
        } else if !ids.isEmpty {
            Button(role: .destructive) {
                Task {
                    for id in ids { await state.closeConnection(id) }
                }
            } label: {
                Label("关闭所选 \(ids.count) 条", systemImage: "xmark.circle")
            }
        }
    }

    /// 入站标签。内核给的 `chains` 第一项永远是它（`["node-x","mixed-in"]` 反转后到队首）。
    static let inboundTags: Set<String> = ["mixed-in", "tun-in"]

    private func chainText(_ conn: ConnectionLiveDetail, nodeNames: [String: String]) -> String {
        Self.chainDisplayText(conn, nodeNames: nodeNames)
    }

    /// 非 private 且是静态的：这段取舍（丢入站、换节点名、拼规则）有真实的判断在里面，
    /// 要能被单测直接盯住，见 `ConnectionChainTextTests`。
    static func chainDisplayText(_ conn: ConnectionLiveDetail, nodeNames: [String: String]) -> String {
        // 丢掉入站标签：它每条连接都一样、零信息量，挤占策略组名显示。
        var tags = conn.chains
        if tags.count > 1, let first = tags.first, Self.inboundTags.contains(first) {
            tags.removeFirst()
        }
        let chain = tags
            .map { nodeNames[$0] ?? $0 }
            .joined(separator: " → ")
        if conn.rule.isEmpty { return chain }
        return chain.isEmpty ? conn.rule : "\(conn.rule)   ·   \(chain)"
    }

    struct DestinationCount: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    static func topDestinations(connections: [ConnectionLiveDetail], nodeNames: [String: String]) -> [DestinationCount] {
        var counts: [String: Int] = [:]
        for conn in connections {
            var tags = conn.chains
            if tags.count > 1, let first = tags.first, inboundTags.contains(first) {
                tags.removeFirst()
            }
            let dest: String
            if let first = tags.first, !first.isEmpty {
                dest = nodeNames[first] ?? first
            } else if !conn.rule.isEmpty {
                dest = conn.rule
            } else {
                dest = "其他"
            }
            counts[dest, default: 0] += 1
        }
        return counts
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { DestinationCount(name: $0.key, count: $0.value) }
    }
}

// MARK: - 顶部指标小子视图（高频数据只在子视图内读，避免全页每秒重绘）

private struct ActiveConnectionsTile: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let count = state.connections.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("活跃连接")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text("\(count)")
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(state.status == .on ? "系统代理运行中" : "代理未开启")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(height: 96)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct LiveSpeedTile: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let up = state.connections.totalUploadRate
        let down = state.connections.totalDownloadRate
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("实时速率")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.uploadTint)
                    Text(Theme.rateOrDash(up))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.downloadTint)
                    Text(Theme.rateOrDash(down))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Text("近 1 分钟")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(height: 96)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TopDestinationsTile: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let nodeNames = state.outboundTagToNodeName
        let top = ConnectionsView.topDestinations(connections: state.connections, nodeNames: nodeNames)
        let topItem = top.first
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                Text("主要去向")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(topItem?.name ?? "—")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(topItem.map { "\($0.count) 条连接" } ?? "暂无活跃连接")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .frame(height: 96)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// 连接表带 sortOrder，每一列都必须有可比较的排序键；进程名可能缺失、开始时间可能缺失，
/// 这里给出稳定的兜底值（缺失的进程排最前、缺失的时间视为最早）。
private extension ConnectionLiveDetail {
    var processSortKey: String { process ?? "" }
    var startSortKey: Date { connection.start ?? .distantPast }
}
