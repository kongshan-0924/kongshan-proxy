import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 配置

struct NodesView: View {
    @Environment(AppState.self) private var state
    @State private var subscriptionURL = ""
    @State private var showsScheduleSheet = false
    @State private var showingManualNode = false
    @State private var pendingImportURL: URL?
    @State private var renamingSource: SubscriptionSource?
    @State private var pendingDelete: AppState.ConfigItem?

    /// 底栏那一行。关闭时也要说出来——「没有自动更新」本身就是用户要知道的状态。
    private var scheduleText: String {
        let settings = state.subscriptionUpdateSettings
        guard settings.enabled else { return "自动更新：已关闭" }
        let next = state.nextSubscriptionUpdateAt?
            .formatted(date: .omitted, time: .shortened) ?? "未安排"
        return "自动更新：每 \(settings.intervalHours) 小时 · 下次 \(next)"
    }

    var body: some View {
        VStack(spacing: 0) {
            importBar
            Divider()
            List {
                ForEach(state.configItems) { item in
                    configRow(item)
                }
            }
            // 同代理页：配置一般只有一两条，交替条纹会在空白处画出一排幽灵行。
            .listStyle(.inset)
            .overlay {
                if state.configItems.isEmpty {
                    ContentUnavailableView(
                        "还没有配置",
                        systemImage: "doc.badge.plus",
                        description: Text("粘贴 Clash 订阅链接导入一个配置，或添加自建 Hysteria2 节点。")
                    )
                }
            }
        }
        // 自动更新状态常驻底栏：解决「设置了却看不到效果」——「下次 18:30」一直可见。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Label(scheduleText, systemImage: "clock.arrow.2.circlepath")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("更改…") { showsScheduleSheet = true }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .sheet(isPresented: $showsScheduleSheet) { SubscriptionScheduleSheet() }
        .navigationTitle("配置")
        .navigationSubtitle(configSummary)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await state.refreshSubscriptions() }
                } label: {
                    Label("刷新全部", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.subscriptions.isEmpty || state.isBusy)
                .help("重新下载全部订阅（⌘R）")

                Button {
                    showingManualNode = true
                } label: {
                    Label("自建节点", systemImage: "plus")
                }
                .help("添加自建节点")
            }
        }
        .sheet(isPresented: $showingManualNode) {
            ManualNodeSheet().environment(state)
        }
        .sheet(item: $pendingImportURL) { url in
            SubscriptionImportSheet(url: url) { subscriptionURL = "" }
        }
        .sheet(item: $renamingSource) { source in
            SubscriptionRenameSheet(source: source) { name in
                Task { await state.renameSubscription(id: source.id, to: name) }
            }
        }
        .confirmationDialog(
            "删除配置“\(pendingDelete?.name ?? "")”？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let item = pendingDelete { delete(item) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("移除该配置的全部节点、策略与规则；正在运行时会重载配置。")
        }
    }

    // MARK: - 配置行

    @ViewBuilder
    private func configRow(_ item: AppState.ConfigItem) -> some View {
        let isActive = state.activeConfigID == item.id
        Button {
            Task { await state.setActiveConfig(item.id) }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))

                Image(systemName: item.isLocal ? "server.rack" : "network.badge.shield.half.filled")
                    .font(.title3)
                    .foregroundStyle(item.isLocal ? Color.orange : Color.blue)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        if isActive {
                            StatusBadge(text: "生效中", tint: .accentColor)
                        }
                    }
                    Text(rowSubtitle(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let usage = item.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
                        let fraction = Double(used) / Double(total)
                        CapacityBar(fraction: fraction, tint: Theme.usageTint(fraction), height: 5)
                            .frame(maxWidth: 260)
                            .padding(.top, 2)
                            .accessibilityLabel("已用流量")
                            .accessibilityValue("\(Int((min(fraction, 1) * 100).rounded()))%")
                    }
                }
                Spacer(minLength: 8)
                rowMenu(item)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .contextMenu { rowMenuItems(item) }
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
    }

    private func rowSubtitle(_ item: AppState.ConfigItem) -> String {
        var parts = ["\(item.nodeCount) 个节点"]
        if let usage = item.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
            // used 可能是 0（刚订阅、还没跑流量）；Theme.bytes 对 0 返回空串，
            // 直接插值会渲染成「 / 100 GB」。用带占位符的版本。
            parts.append("\(Theme.bytesOrDash(used)) / \(Theme.bytes(total))")
        }
        if let expires = item.usage?.expiresAt {
            parts.append("\(expires.formatted(date: .abbreviated, time: .omitted)) 到期")
        }
        if let updated = item.lastUpdatedAt {
            parts.append("更新于 \(updated.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    /// 行菜单的内容。省略号按钮与右键菜单共用：右键是 macOS 列表的肌肉记忆，
    /// 只给一个 22pt 的小按钮等于让用户先找靶子再点。
    @ViewBuilder
    private func rowMenuItems(_ item: AppState.ConfigItem) -> some View {
        if !item.isLocal, let source = state.subscriptions.first(where: { $0.id == item.id }) {
            Button("重命名…") { renamingSource = source }
            Button("立即更新") { Task { await state.refreshSubscription(id: source.id) } }
            Toggle("参与定时更新", isOn: Binding(
                get: { source.autoUpdate },
                set: { enabled in Task { await state.setSubscriptionAutoUpdate(id: source.id, enabled: enabled) } }
            ))
            Divider()
        }
        Button("删除", role: .destructive) { pendingDelete = item }
    }

    @ViewBuilder
    private func rowMenu(_ item: AppState.ConfigItem) -> some View {
        Menu {
            rowMenuItems(item)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .disabled(state.isBusy)
    }

    private func delete(_ item: AppState.ConfigItem) {
        Task {
            if item.isLocal {
                await state.removeLocalConfig()
            } else {
                await state.removeSubscription(id: item.id)
            }
        }
    }

    // MARK: - 导入

    private var importBar: some View {
        HStack(spacing: 8) {
            TextField("粘贴 Clash YAML 订阅链接", text: $subscriptionURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit(beginImport)
            Button("导入") { beginImport() }
                .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private var configSummary: String {
        "\(state.configItems.count) 个配置 · 生效：\(state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无")"
    }

    private func beginImport() {
        let value = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard let url = URL(string: value), url.scheme != nil else {
            state.errorMessage = "订阅 URL 无效"
            return
        }
        pendingImportURL = url
    }
}


extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// 导入是异步网络操作：sheet 保持打开显示进度，失败在 sheet 内给出原因，
/// 成功才关闭。此前是先关 sheet 再后台导入，失败没有任何可见提示。
private struct SubscriptionImportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onImported: () -> Void

    @State private var name = ""
    @State private var autoUpdate = true
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("导入订阅")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("名称", text: $name, prompt: Text(url.host ?? "订阅"))
                        .disabled(isImporting)
                    Toggle("参与定时自动更新", isOn: $autoUpdate)
                        .disabled(isImporting)
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let importError {
                            Label(importError, systemImage: "exclamationmark.octagon.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text("正在下载并解析…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入") { beginImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting)
            }
            .padding(16)
        }
        .frame(width: 440, height: 300)
    }

    private func beginImport() {
        guard !isImporting else { return }
        isImporting = true
        importError = nil
        Task {
            await state.importSubscription(url: url, name: name, autoUpdate: autoUpdate)
            isImporting = false
            if let message = state.errorMessage {
                importError = message
                // 错误已经就地显示，不再让全局横幅重复报一次。
                state.dismissError()
            } else {
                onImported()
                dismiss()
            }
        }
    }
}

private struct SubscriptionRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: SubscriptionSource
    let onConfirm: (String) -> Void

    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名订阅")
                .font(.headline)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onConfirm(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = source.name }
    }
}
