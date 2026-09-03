import AppKit
import KongshanCore
import SwiftUI

/// 连接监控页：实时列出活跃连接（目标主机 / 进程、命中的规则与出站链路、上下行流量），
/// 支持单条关闭与工具栏一键全部关闭。只在本页可见时订阅，离开即停。
///
/// 用系统 `Table`：活动监视器那类实时表格就是它——列可排序、列宽可拖、AppKit 承载，
/// 上千行每秒刷新也比自绘 `LazyVStack` 省。
struct ConnectionsView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\ConnectionLiveDetail.totalRate, order: .reverse)]
    @State private var selection: Set<ConnectionLiveDetail.ID> = []
    @State private var inspectedConnection: ConnectionLiveDetail?
    @State private var confirmsCloseAll = false

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
        // 只算一遍：`filteredConnections` 每次访问都要 filter + sort。
        let list = filteredConnections
        // 出站 tag → 节点名。内核回报的链路里节点是 `node-<uuid>` 形式的内部 tag，
        // 直接显示就是一串 UUID 而不是「DMIT-Trojan」——信息量为零还占满整行。
        let nodeNames = Dictionary(
            state.nodes.map { (ConfigGenerator.outboundTag(for: $0), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return content(list: list, nodeNames: nodeNames)
            .navigationTitle("连接")
            .navigationSubtitle(subtitle)
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索目标、进程或规则")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        confirmsCloseAll = true
                    } label: {
                        Label("全部关闭", systemImage: "xmark.circle")
                    }
                    .disabled(state.connections.isEmpty)
                    .help("关闭全部活跃连接")
                }
            }
            // 误点一下会掐掉所有进行中的下载和长连接，必须有确认。
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
            .onAppear { state.startConnectionsMonitoring() }
            .onDisappear { state.stopConnectionsMonitoring() }
            .sheet(item: $inspectedConnection) { connection in
                ConnectionRouteDetail(connection: connection, nodeNames: nodeNames)
            }
    }

    /// 条数与总速率放副标题——活动监视器就是把统计放在这里，而不是另画一行工具条。
    private var subtitle: String {
        guard state.status == .on else { return "代理未开启" }
        let count = state.connections.count
        guard count > 0 else { return "暂无活跃连接" }
        return "\(count) 条 · ↑ \(Theme.rateOrDash(state.connections.totalUploadRate)) · ↓ \(Theme.rateOrDash(state.connections.totalDownloadRate))"
    }

    @ViewBuilder
    private func content(list: [ConnectionLiveDetail], nodeNames: [String: String]) -> some View {
        if state.status != .on {
            ContentUnavailableView(
                "代理未开启",
                systemImage: "bolt.slash",
                description: Text("开启系统代理或 TUN 后，这里会显示实时活跃连接。")
            )
        } else if state.connections.isEmpty {
            ContentUnavailableView("暂无活跃连接", systemImage: "point.3.connected.trianglepath.dotted")
        } else if list.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            table(list, nodeNames: nodeNames)
        }
    }

    private func table(_ list: [ConnectionLiveDetail], nodeNames: [String: String]) -> some View {
        Table(list, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("目标", value: \.host) { conn in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(conn.network.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(conn.host)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let process = conn.process {
                        Text(process)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .width(min: 200, ideal: 300)

            TableColumn("规则 · 链路", value: \.rule) { conn in
                Text(chainText(conn, nodeNames: nodeNames))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 160, ideal: 240)

            TableColumn("↑ 速率", value: \.uploadRate) { conn in
                rateCell(conn.uploadRate, active: conn.totalRate > 0)
            }
            .width(min: 76, ideal: 88)

            TableColumn("↓ 速率", value: \.downloadRate) { conn in
                rateCell(conn.downloadRate, active: conn.totalRate > 0)
            }
            .width(min: 76, ideal: 88)

            TableColumn("↑ 累计", value: \.upload) { conn in
                Text(Theme.bytesOrDash(conn.upload))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 72, ideal: 84)

            TableColumn("↓ 累计", value: \.download) { conn in
                Text(Theme.bytesOrDash(conn.download))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 72, ideal: 84)

            TableColumn("") { conn in
                Button {
                    Task { await state.closeConnection(conn.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("关闭此连接")
                .accessibilityLabel("关闭 \(conn.host)")
            }
            .width(28)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ConnectionLiveDetail.ID.self) { ids in
            contextMenu(for: ids, in: list)
        } primaryAction: { ids in
            if let id = ids.first, let conn = list.first(where: { $0.id == id }) {
                inspectedConnection = conn
            }
        }
    }

    private func rateCell(_ value: Int64, active: Bool) -> some View {
        Text(Theme.rateOrDash(value))
            .font(.callout.monospacedDigit())
            .foregroundStyle(active ? .primary : .secondary)
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
            if let process = conn.process, !process.isEmpty {
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
                inspectedConnection = conn
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

    private func chainText(_ conn: ConnectionLiveDetail, nodeNames: [String: String]) -> String {
        // 策略组名（`🚀 节点选择` 等）本来就可读，只把 `node-<uuid>` 换成节点名。
        let chain = conn.chains
            .map { nodeNames[$0] ?? $0 }
            .joined(separator: " → ")
        if conn.rule.isEmpty { return chain }
        return chain.isEmpty ? conn.rule : "\(conn.rule)   ·   \(chain)"
    }
}

private struct ConnectionRouteDetail: View {
    let connection: ConnectionLiveDetail
    let nodeNames: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("目标", value: connection.host)
                    if let process = connection.process { LabeledContent("进程", value: process) }
                    LabeledContent("命中规则", value: connection.rule.isEmpty ? "未报告" : connection.rule)
                }
                Section("出站链路") {
                    ForEach(Array(connection.chains.enumerated()), id: \.offset) { index, tag in
                        LabeledContent("\(index + 1)") {
                            Text(nodeNames[tag] ?? tag)
                                .font(.body.monospaced())
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 460, height: 320)
    }
}
