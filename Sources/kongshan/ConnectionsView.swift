import AppKit
import KongshanCore
import SwiftUI

/// 连接监控页：实时列出活跃连接（目标主机 / 进程、命中的规则与出站链路、上下行流量），
/// 支持单条关闭与右上角一键全部关闭。只在本页可见时轮询，离开即停。
struct ConnectionsView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var sortOption: ConnectionSortOption = .defaultOrder
    @State private var inspectedConnection: ConnectionLiveDetail?

    private var filteredConnections: [ConnectionLiveDetail] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = query.isEmpty ? state.connections : state.connections.filter { conn in
            conn.host.localizedCaseInsensitiveContains(query)
                || (conn.process?.localizedCaseInsensitiveContains(query) ?? false)
                || conn.rule.localizedCaseInsensitiveContains(query)
                || conn.chains.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
        switch sortOption {
        case .defaultOrder: break
        case .totalRate: result.sort { $0.totalRate > $1.totalRate }
        case .uploadRate: result.sort { $0.uploadRate > $1.uploadRate }
        case .downloadRate: result.sort { $0.downloadRate > $1.downloadRate }
        }
        return result
    }

    var body: some View {
        // 只算一遍。`filteredConnections` 每次访问都要 filter + sort，而工具栏里的汇总、
        // 计数和下面的列表都要用它——连接上千条时每秒重复三四遍纯属白工。
        let list = filteredConnections
        // 出站 tag → 节点名。内核回报的链路里节点是 `node-<uuid>` 形式的内部 tag，
        // 直接显示就是一串 UUID 而不是「DMIT-Trojan」——信息量为零还占满整行。
        // 每次渲染建一次即可：节点集合不大，而按需线性扫会变成
        // 可见行数 × 链路长度 次遍历。
        let nodeNames = Dictionary(
            state.nodes.map { (ConfigGenerator.outboundTag(for: $0), $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        return VStack(spacing: 0) {
            header
            Divider()
            if state.status == .on && !state.connections.isEmpty {
                HStack {
                    SearchField(text: $searchText, placeholder: "搜索目标域名、进程或出站规则…")
                        .frame(maxWidth: 320)
                    Menu {
                        Picker("排序", selection: $sortOption) {
                            ForEach(ConnectionSortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Label(sortOption.rawValue, systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    // 汇总：把"这些连接一共传了多少"直接给出来。
                    // 只列每条连接的累计量、要用户自己心算加总是没意义的。
                    HStack(spacing: 10) {
                        Text("累计 ↑ \(Self.bytesOrDash(list.reduce(0) { $0 + $1.upload }))")
                        Text("↓ \(Self.bytesOrDash(list.reduce(0) { $0 + $1.download }))")
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    Divider().frame(height: 10)
                    Text("当前显示 \(list.count) / \(state.connections.count) 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                Divider()
            }
            content(list: list, nodeNames: nodeNames)
        }
        .pageBackground()
        .navigationTitle("连接")
        .onAppear { state.startConnectionsMonitoring() }
        .onDisappear { state.stopConnectionsMonitoring() }
        .sheet(item: $inspectedConnection) { connection in
            ConnectionRouteDetail(connection: connection, nodeNames: nodeNames)
        }
    }

    private var header: some View {
        PageHeader(title: "连接", subtitle: "实时活跃连接；显示出站链路与命中的规则") {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Label("↑ \(Self.rateOrDash(state.connections.totalUploadRate))", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(.blue)
                    Label("↓ \(Self.rateOrDash(state.connections.totalDownloadRate))", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.green)
                }
                .font(.caption.monospacedDigit())
                Text("\(state.connections.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    Task { await state.closeAllActiveConnections() }
                } label: {
                    Label("全部关闭", systemImage: "xmark.circle")
                }
                .disabled(state.connections.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func content(list: [ConnectionLiveDetail], nodeNames: [String: String]) -> some View {
        if state.status != .on {
            ContentUnavailableView(
                "代理未开启",
                systemImage: "bolt.slash",
                description: Text("开启系统代理或 TUN 后，这里会显示实时活跃连接。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.connections.isEmpty {
            ContentUnavailableView(
                "暂无活跃连接",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            if list.isEmpty {
                ContentUnavailableView(
                    "未匹配到相关连接",
                    systemImage: "magnifyingglass",
                    description: Text("请尝试搜索其他关键字。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { conn in
                            row(conn, nodeNames: nodeNames)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func row(_ conn: ConnectionLiveDetail, nodeNames: [String: String]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(conn.network.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 4))
                    Text(conn.host)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let process = conn.process {
                        Text(process)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Text(chainText(conn, nodeNames: nodeNames))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("↑ \(Self.rateOrDash(conn.uploadRate))   ↓ \(Self.rateOrDash(conn.downloadRate))")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(conn.totalRate > 0 ? .primary : .secondary)
                Text("累计 ↑ \(Self.bytesOrDash(conn.upload))   ↓ \(Self.bytesOrDash(conn.download))")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
            Button {
                Task { await state.closeConnection(conn.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭此连接")
        }
        .padding(.vertical, 7)
        .contextMenu {
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

    /// 0 时用固定占位符，避免空串导致布局跳动。
    static func rateOrDash(_ value: Int64) -> String {
        Theme.rateOrDash(value)
    }

    static func bytesOrDash(_ value: Int64) -> String {
        Theme.bytesOrDash(value)
    }
}

private struct ConnectionRouteDetail: View {
    let connection: ConnectionLiveDetail
    let nodeNames: [String: String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("命中链路")
                    .font(.headline)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("关闭")
            }
            LabeledContent("目标", value: connection.host)
            if let process = connection.process { LabeledContent("进程", value: process) }
            LabeledContent("命中规则", value: connection.rule.isEmpty ? "未报告" : connection.rule)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("出站链路").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(connection.chains.enumerated()), id: \.offset) { index, tag in
                    HStack(spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)
                        Text(nodeNames[tag] ?? tag)
                            .font(.system(.body, design: .monospaced))
                    }
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 260)
    }
}

private enum ConnectionSortOption: String, CaseIterable, Identifiable {
    case defaultOrder = "累计流量"
    case totalRate = "实时总速率"
    case downloadRate = "下载速率"
    case uploadRate = "上传速率"

    var id: Self { self }
}
