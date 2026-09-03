import AppKit
import KongshanCore
import SwiftUI

/// 局域网共享页。
///
/// 把本机的分流与节点共享给同网段的设备：对方在系统或浏览器里把 HTTP / SOCKS5 代理
/// 填成「本机 IP:端口」即可。入口是**独立于本机代理入口的另一个监听**，
/// 开关它不会影响本机自己走的系统代理。
struct SharingView: View {
    @Environment(AppState.self) private var state
    @State private var draft = LANSharingSettings.defaults
    @State private var newCIDR = ""

    var body: some View {
        Form {
            switchSection
            if state.lanSharing.enabled { addressSection }
            configurationSection
            clientsSection
        }
        .formStyle(.grouped)
        .navigationTitle("共享")
        .navigationSubtitle(subtitle)
        .onAppear {
            draft = state.lanSharing
            state.startLANClientsMonitoring()
        }
        .onDisappear { state.stopLANClientsMonitoring() }
        .onChange(of: state.lanSharing) { _, new in draft = new }
    }

    private var subtitle: String {
        guard state.lanSharing.enabled else { return "未开启" }
        guard let port = state.lanSharingBoundPort else { return "等待代理开启" }
        let active = state.lanClients.filter { $0.stats.activeConnections > 0 }.count
        return "监听 \(port) · \(active) 个设备在用 · 共 \(state.lanClients.count) 个来访过"
    }

    // MARK: - 开关

    private var switchSection: some View {
        Section {
            Toggle("共享给局域网", isOn: enabledBinding)
                .disabled(!state.isReady)
            if state.lanSharing.enabled, state.lanSharingBoundPort == nil {
                Label("代理未开启，共享入口会在开启代理后自动启动。", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("局域网共享")
        } footer: {
            Text("同网段的设备把 HTTP 与 SOCKS5 代理都填成下面的地址，就能走本机的分流规则与节点。同一个端口同时支持这两种协议。入口独立于本机代理，开关它不会中断你自己正在走的连接。")
        }
    }

    // MARK: - 地址

    private var addressSection: some View {
        Section {
            if let port = state.lanSharingBoundPort {
                let addresses = state.lanProxyAddresses
                if addresses.isEmpty {
                    Label("当前没有可用的局域网地址（未连接网络？）", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    ForEach(addresses, id: \.self) { address in
                        LabeledContent("在其他设备填写") {
                            HStack(spacing: 8) {
                                Text("\(address):\(String(port))")
                                    .font(.body.monospaced())
                                    .textSelection(.enabled)
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString("\(address):\(String(port))", forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(.borderless)
                                .help("拷贝地址")
                            }
                        }
                    }
                }
            }
        } header: {
            Text("连接地址")
        } footer: {
            Text("首次开启时 macOS 可能询问是否允许接受传入连接，需要点「允许」。地址随网络变化，换 Wi-Fi 后请重新确认。")
        }
    }

    // MARK: - 配置

    private var configurationSection: some View {
        Section {
            LabeledContent("监听端口") {
                TextField("端口", value: $draft.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 90)
                    .font(.body.monospaced())
            }

            if draft.allowedCIDRs.isEmpty {
                Text("未限制来源：同网段的任何私网地址都能接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(draft.allowedCIDRs.enumerated()), id: \.offset) { index, value in
                HStack(spacing: 8) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(value)
                        .font(.body.monospaced())
                    Spacer(minLength: 8)
                    Button(role: .destructive) {
                        draft.allowedCIDRs.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("删除该网段")
                }
            }
            HStack(spacing: 8) {
                TextField("192.168.1.0/24 或 192.168.1.7", text: $newCIDR)
                    .font(.body.monospaced())
                    .onSubmit(addCIDR)
                Button("添加网段") { addCIDR() }
                    .disabled(newCIDR.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                if draft != state.lanSharing {
                    StatusBadge(text: "有未应用的修改", tint: .orange)
                }
                Spacer()
                Button("放弃修改") { draft = state.lanSharing }
                    .disabled(draft == state.lanSharing)
                Button("应用") {
                    Task { await state.applyLANSharing(draft) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == state.lanSharing)
            }
        } header: {
            Text("配置")
        } footer: {
            Text("端口需在 1024–49151 之间。来源白名单留空表示允许全部私网地址；填了则只允许列出的网段。无论如何都不接受公网来源——机器万一拿到公网 IP，也不会变成互联网上的开放代理。同网段内不做身份校验，公共 Wi-Fi 请谨慎开启。应用端口或白名单的改动会重建共享入口，已连接的设备需要重连。")
        }
    }

    // MARK: - 客户端

    @ViewBuilder
    private var clientsSection: some View {
        Section {
            if !state.lanSharing.enabled {
                Text("开启共享后，这里会列出正在使用的设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if state.lanClients.isEmpty {
                Text("还没有设备接入。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.lanClients) { client in
                    clientRow(client)
                }
            }
        } header: {
            Text("已接入的设备")
        } footer: {
            if state.lanSharing.enabled, !state.lanClients.isEmpty {
                Text("断开的设备仍会留在列表里显示累计用量，直到关闭共享。速率按每秒采样的差值计算。")
            }
        }
    }

    private func clientRow(_ client: LANClientLiveStats) -> some View {
        let active = client.stats.activeConnections > 0
        return HStack(spacing: 10) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(client.address)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text(active
                     ? "\(client.stats.activeConnections) 条连接"
                     : "已断开 · 最后活动 \(client.stats.lastActiveAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                // 高频数值不做动画，理由同仪表盘：弹簧插值会按刷新率持续重绘。
                Text("↑ \(Theme.rateOrDash(client.uploadRate))   ↓ \(Theme.rateOrDash(client.downloadRate))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(client.totalRate > 0 ? .primary : .secondary)
                Text("累计 \(Theme.bytesOrDash(client.stats.total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.lanSharing.enabled },
            set: { enabled in
                var next = state.lanSharing
                next.enabled = enabled
                // 开关立即生效；端口与白名单要按「应用」。
                draft.enabled = enabled
                Task { await state.applyLANSharing(next) }
            }
        )
    }

    private func addCIDR() {
        let value = newCIDR.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !draft.allowedCIDRs.contains(value) else { return }
        draft.allowedCIDRs.append(value)
        newCIDR = ""
    }
}
