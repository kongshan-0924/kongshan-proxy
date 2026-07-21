import KongshanCore
import SwiftUI

/// 连接监控页：实时列出活跃连接（目标主机 / 进程、命中的规则与出站链路、上下行流量），
/// 支持单条关闭与右上角一键全部关闭。只在本页可见时轮询，离开即停。
struct ConnectionsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .pageBackground()
        .navigationTitle("连接")
        .onAppear { state.startConnectionsMonitoring() }
        .onDisappear { state.stopConnectionsMonitoring() }
    }

    private var header: some View {
        PageHeader(title: "连接", subtitle: "实时活跃连接；显示出站链路与命中的规则") {
            HStack(spacing: 10) {
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
    private var content: some View {
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(state.connections) { conn in
                        row(conn)
                        Divider()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }
        }
    }

    private func row(_ conn: ConnectionDetail) -> some View {
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
                Text(chainText(conn))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text("↑ \(Self.bytes(conn.upload))   ↓ \(Self.bytes(conn.download))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
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
    }

    private func chainText(_ conn: ConnectionDetail) -> String {
        let chain = conn.chains.joined(separator: " → ")
        if conn.rule.isEmpty { return chain }
        return chain.isEmpty ? conn.rule : "\(conn.rule)   ·   \(chain)"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }
}
