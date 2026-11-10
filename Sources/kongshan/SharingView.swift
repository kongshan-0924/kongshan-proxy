import AppKit
import KongshanCore
import SwiftUI

/// 局域网共享页。
///
/// 把本机的分流与节点共享给同网段的设备：对方在系统或浏览器里把 HTTP / SOCKS5 代理
/// 填成「本机 IP:端口」即可。入口是独立于本机代理入口的另一个监听，
/// 开关它不会影响本机自己走的系统代理。
struct SharingView: View {
    @Environment(AppState.self) private var state
    @State private var draft = LANSharingSettings.defaults
    /// 离开本视图时把没应用的草稿交给上层保管，回来时接着改。连接页切到「本机」分段时本视图会被销毁，
    /// 不交出去的话改到一半的端口、白名单就丢了（2026-11-10 审计）。
    @Binding private var parkedDraft: LANSharingSettings?

    init(parkedDraft: Binding<LANSharingSettings?> = .constant(nil)) {
        _parkedDraft = parkedDraft
    }
    @State private var newCIDR = ""
    /// 本机局域网地址。取一次要遍历网卡（`getifaddrs`）；设备列表每秒刷新会带着整页重算，
    /// 不能每次求值都取，进页面和监听端口变化时取一次即可。
    @State private var lanAddresses: [String] = []

    var body: some View {
        TilePage {
            TileMasonry(minColumnWidth: 300, maxColumns: 2) {
                shareTile
                accessTile
                configTile
                LANClientsTile()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.lanSharing.enabled { PageStatusBar(subtitle) }
        }
        .onAppear {
            if var parked = parkedDraft {
                // 与下面 onChange 同一条规则：开关是立即生效的，以当前状态为准，其余保留用户没应用的输入。
                parked.enabled = state.lanSharing.enabled
                draft = parked
            } else {
                draft = state.lanSharing
            }
            lanAddresses = state.lanProxyAddresses
            state.startLANClientsMonitoring()
        }
        .onChange(of: state.lanSharingBoundPort) { lanAddresses = state.lanProxyAddresses }
        .onDisappear {
            state.stopLANClientsMonitoring()
            parkedDraft = draft != state.lanSharing ? draft : nil
        }
        // 草稿脏着（改了端口或白名单还没应用）时只同步开关，不冲掉输入。
        .onChange(of: state.lanSharing) { old, new in
            if draft == old { draft = new } else { draft.enabled = new.enabled }
        }
    }

    private var subtitle: String {
        guard state.lanSharing.enabled else { return "未开启" }
        guard let port = state.lanSharingBoundPort else {
            return state.lanSharingFailure == nil ? "等待代理开启" : "未启动：端口 \(state.lanSharing.port) 被占用"
        }
        let active = state.lanClients.filter { $0.stats.activeConnections > 0 }.count
        return "监听 \(port) · \(active) 个设备在用 · 共 \(state.lanClients.count) 个来访过"
    }

    // MARK: - 小窗 1：「共享」

    private var shareTile: some View {
        TileCard(
            "共享",
            symbol: "antenna.radiowaves.left.and.right",
            height: nil,
            trailing: {
                Toggle("", isOn: enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!state.isReady)
                    .help("开启或关闭局域网共享")
            },
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            text: state.lanSharing.enabled
                                ? (state.lanSharingBoundPort != nil ? "共享运行中" : (state.lanSharingFailure != nil ? "未启动" : "等待代理开启"))
                                : "已关闭",
                            style: !state.lanSharing.enabled ? Theme.neutral
                                : state.lanSharingFailure != nil ? Theme.danger
                                : state.lanSharingBoundPort != nil ? Theme.current
                                : Theme.warning
                        )
                        if let port = state.lanSharingBoundPort {
                            Text("端口 \(port)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }

                    if state.lanSharingFailure == nil, state.lanSharing.enabled, state.lanSharingBoundPort == nil {
                        Text("代理未开启，共享入口将在代理开启后自动启动。")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    if state.lanSharing.enabled, state.lanSharingBoundPort != nil {
                        let addresses = lanAddresses
                        if addresses.isEmpty {
                            Text("未检测到局域网地址（请检查网络连接）")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("本机局域网地址")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                                ForEach(addresses, id: \.self) { address in
                                    HStack(spacing: 8) {
                                        Text(address)
                                            .font(.system(.title3, design: .monospaced, weight: .bold))
                                            .textSelection(.enabled)
                                        Spacer()
                                        copyButton(address, help: "拷贝本机局域网 IP")
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                    }

                    Text("同网段设备可将代理指向本机，共用当前节点与规则。")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .help("同网段的设备把 HTTP 与 SOCKS5 代理都填成此地址与端口，就能走本机的分流规则与节点。开关独立于本机代理，开关它不会影响本机网络。")
                }
                .padding(.vertical, 4)
            }
        )
    }

    // MARK: - 小窗 2：「接入方式」

    private var accessTile: some View {
        TileCard("接入方式", symbol: "iphone.gen3", height: nil) {
            VStack(alignment: .leading, spacing: 6) {
                if let port = state.lanSharingBoundPort {
                    let addresses = lanAddresses
                    if addresses.isEmpty {
                        TileEmptyNote(text: "当前没有可用的局域网地址")
                    } else {
                        ForEach(addresses, id: \.self) { address in
                            TileRow(symbol: "server.rack", "代理服务器", subtitle: address, subtitleMonospaced: true, showsDivider: true) {
                                copyButton(address, help: "拷贝服务器 IP")
                            }
                        }
                        TileRow(symbol: "number", "端口", subtitle: String(port), subtitleMonospaced: true, showsDivider: true) {
                            copyButton(String(port), help: "拷贝端口")
                        }
                        TileRow(symbol: "checkmark.shield", "协议类型", subtitle: "HTTP 与 SOCKS5 同端口均支持", showsDivider: false)
                    }
                } else if let failure = state.lanSharingFailure {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger.icon)
                            .font(.caption)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(Theme.danger.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 8)
                } else {
                    TileRow(symbol: "number", "配置端口", subtitle: String(draft.port), subtitleMonospaced: true, showsDivider: false)
                    TileEmptyNote(text: "开启共享后在此显示填写入参")
                }

                Text("手机：Wi-Fi 详情 → 配置代理 → 手动，填入服务器与端口。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
                    .help("连不上时依次检查：\n① 设备与本机处于同一 Wi-Fi（同一网段）；\n② 路由器未开启「AP 隔离」；\n③ 系统设置 → 隐私与安全性 → 本地网络中 kongshan 已开启；\n④ macOS 防火墙已允许传入连接。")
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 小窗 3：「配置」

    private var configTile: some View {
        TileCard(
            "配置",
            symbol: "gearshape",
            detail: draft != state.lanSharing ? "未应用" : nil,
            height: nil,
            trailing: {
                if draft != state.lanSharing {
                    HStack(spacing: 6) {
                        Button("放弃") {
                            draft = state.lanSharing
                        }
                        .buttonStyle(.pill)
                        .help("放弃所有未应用的修改")

                        Button("应用") {
                            Task { await state.applyLANSharing(draft) }
                        }
                        .buttonStyle(.pillProminent)
                        .help("应用端口与白名单设置")
                    }
                }
            },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("监听端口")
                            .font(.callout)
                            .foregroundStyle(Theme.textSecondary)
                        TextField("端口", value: $draft.port, format: .number.grouping(.never), prompt: Theme.inputPrompt("端口"))
                            .labelsHidden()
                            .font(.callout.monospacedDigit())
                            .inputField()
                            .frame(width: 80)
                        Spacer()
                        Text("范围 1024–49151")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    HStack(spacing: 8) {
                        TextField("添加白名单网段", text: $newCIDR, prompt: Theme.inputPrompt("如 192.168.1.0/24"))
                            .labelsHidden()
                            .font(.callout.monospaced())
                            .inputField()
                            .onSubmit(addCIDR)
                        Button("添加") { addCIDR() }
                            .buttonStyle(.pill)
                            .disabled(newCIDR.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            },
            content: {
                if draft.allowedCIDRs.isEmpty {
                    // 「未限制来源」不是无害空态：用 warning 标记明确安全含义，不降为灰色占位。
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning.icon)
                            .font(.caption)
                        Text("未限制来源：同网段私网地址均可接入")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    .help("来源白名单留空表示允许全部私网地址；填了则只允许列出的网段。无论如何都不接受公网来源。")
                } else {
                    ForEach(Array(draft.allowedCIDRs.enumerated()), id: \.offset) { index, cidr in
                        TileRow(
                            symbol: "network",
                            cidr,
                            monospaced: true,
                            showsDivider: index != draft.allowedCIDRs.count - 1
                        ) {
                            Button(role: .destructive) {
                                draft.allowedCIDRs.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除网段 \(cidr)")
                            .help("删除该网段")
                        }
                    }
                }
            }
        )
    }

    // MARK: - 辅助

    private func copyButton(_ value: String, help: String = "拷贝") -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.caption)
                .frame(minWidth: 24, minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(help)
        .help(help)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.lanSharing.enabled },
            set: { enabled in
                var next = state.lanSharing
                next.enabled = enabled
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

// MARK: - 已接入设备小子视图（高频数据只在子视图内读）

struct LANClientsTile: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let clients = state.lanClients
        let activeCount = clients.filter { $0.stats.activeConnections > 0 }.count
        TileCard(
            "已接入设备",
            symbol: "laptopcomputer.and.iphone",
            detail: clients.isEmpty ? nil : "\(activeCount) 活跃 / 共 \(clients.count) 设备",
            height: nil
        ) {
            if !state.lanSharing.enabled {
                TileEmptyNote(symbol: "laptopcomputer.and.iphone", text: "开启共享后在此显示接入设备")
            } else if clients.isEmpty {
                TileEmptyNote(symbol: "laptopcomputer.and.iphone", text: "暂无设备接入")
            } else {
                ForEach(clients) { client in
                    clientRow(client, showsDivider: client.id != clients.last?.id)
                }
            }
        }
    }

    private func clientRow(_ client: LANClientLiveStats, showsDivider: Bool) -> some View {
        let active = client.stats.activeConnections > 0
        let subtitle = active
            ? "\(client.stats.activeConnections) 条连接"
            : "已断开 · 最后活动 \(client.stats.lastActiveAt.formatted(date: .omitted, time: .shortened))"
        return TileRow(
            symbol: active ? "wifi" : "wifi.slash",
            client.address,
            subtitle: subtitle,
            monospaced: true,
            showsDivider: showsDivider
        ) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("↑ \(Theme.rateOrDash(client.uploadRate))  ↓ \(Theme.rateOrDash(client.downloadRate))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(client.totalRate > 0 ? Theme.textPrimary : Theme.textSecondary)
                Text("累计 \(Theme.bytesOrDash(client.stats.total))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
