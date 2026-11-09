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

    /// 自动更新卡片的说明。关闭时也明确显示，避免用户设置了却找不到状态。
    private var scheduleText: String {
        let settings = state.subscriptionUpdateSettings
        guard settings.enabled else { return "已关闭" }
        let next = state.nextSubscriptionUpdateAt?
            .formatted(date: .omitted, time: .shortened) ?? "未安排"
        return "每 \(settings.intervalHours) 小时 / 下次 \(next)"
    }

    var body: some View {
        // 原型布局：左侧配置列表卡撑满到底，右侧「添加配置 / 自动更新」两张卡。
        // 用宽度阈值而不是 ViewThatFits：长配置名的理想宽度会把 ViewThatFits 误判成单列。
        // 阈值 700：960 窗口内容宽 732 仍保持两列（右栏收窄到 320，列表仍有约 396）。
        GeometryReader { geo in
            let contentWidth = max(0, geo.size.width - Theme.pagePadding * 2)
            let availableHeight = max(0, geo.size.height - Theme.pagePadding * 2)
            ScrollView {
                Group {
                    if contentWidth >= 700 {
                        HStack(alignment: .top, spacing: Theme.cardGap) {
                            configCard(maxHeight: availableHeight)
                            VStack(spacing: Theme.cardGap) {
                                importBar
                                autoUpdateCard
                                activeConfigCard
                            }
                            .frame(width: 320)
                        }
                    } else {
                        VStack(spacing: Theme.cardGap) {
                            configCard(maxHeight: availableHeight)
                            importBar
                            autoUpdateCard
                            activeConfigCard
                        }
                    }
                }
                .padding(Theme.pagePadding)
                .frame(minHeight: availableHeight, alignment: .top)
            }
            .background(Theme.canvasBackground)
        }
        .groupBoxStyle(CardGroupBoxStyle())
        .labeledContentStyle(CardRowLabeledContentStyle())
        .foregroundStyle(Theme.textPrimary)
        .sheet(isPresented: $showsScheduleSheet) { SubscriptionScheduleSheet().sheetChrome() }
        .buttonStyle(.pill)
        .pageTopBar {
                Button {
                    Task { await state.refreshSubscriptions() }
                } label: {
                    Label("更新全部", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.subscriptions.isEmpty || state.isBusy)
                .help("重新下载全部订阅（⌘R）")

                Button {
                    showingManualNode = true
                } label: {
                    Label("添加节点", systemImage: "plus")
                }
                .help("添加自建节点")
        }
        .sheet(isPresented: $showingManualNode) {
            ManualNodeSheet().environment(state).sheetChrome()
        }
        .sheet(item: $pendingImportURL) { url in
            SubscriptionImportSheet(url: url) { subscriptionURL = "" }
                .sheetChrome()
        }
        .sheet(item: $renamingSource) { source in
            SubscriptionRenameSheet(source: source) { name in
                Task { await state.renameSubscription(id: source.id, to: name) }
            }
            .sheetChrome()
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

    /// 配置列表卡（贴合内容，配置多时撑满后卡内滚动）。
    private func configCard(maxHeight: CGFloat) -> some View {
        let items = state.configItems   // 算一次：原先每行都要重算整份列表来判断是否首行
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("配置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(configSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Button("更新全部") {
                    Task { await state.refreshSubscriptions() }
                }
                .controlSize(.small)
                .disabled(state.subscriptions.isEmpty || state.isBusy)
                .help("重新下载全部订阅（⌘R）")
            }

            if items.isEmpty {
                TileEmptyNote(symbol: "doc.badge.plus", text: "暂无配置，粘贴订阅链接或添加自建节点")
                    .padding(.vertical, 24)
            } else {
                HuggingScrollStack(spacing: 0, estimatedHeight: CGFloat(items.count) * 56) {
                    ForEach(items) { item in
                        if item.id != items.first?.id {
                            Theme.separator.frame(height: 0.5)
                        }
                        configRow(item)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // 底色先于高度上限挂上：卡片贴合内容；上限只决定配置很多时何时改为卡内滚动。
        // 反过来挂会把卡拉到整页高、内容被竖直居中（2026-11-09 审计）。
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .frame(maxHeight: maxHeight, alignment: .top)
    }

    @ViewBuilder
    private func configRow(_ item: AppState.ConfigItem) -> some View {
        let isActive = state.activeConfigID == item.id
        let title = IconTile.split(item.name)
        HStack(spacing: 12) {
            // 右侧是独立操作，不嵌进整行按钮，避免菜单点击误触切换配置。
            Button {
                Task { await state.setActiveConfig(item.id) }
            } label: {
                HStack(spacing: 12) {
                    IconTile(
                        emoji: title.emoji,
                        symbol: item.isLocal ? "server.rack" : "network.badge.shield.half.filled",
                        size: 36,
                        isActive: isActive
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title.title)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.name)
                                .layoutPriority(1)
                            if isActive {
                                StatusBadge(text: "生效中", style: Theme.current)
                                    .fixedSize()
                            }
                        }
                        Text(rowSubtitle(item))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let usage = item.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
                            usageRow(used: used, total: total, expiresAt: item.usage?.expiresAt)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)

            if !isActive {
                Button("设为生效") {
                    Task { await state.setActiveConfig(item.id) }
                }
                .controlSize(.small)
                .fixedSize()
                .disabled(state.isBusy)
            }
            rowMenu(item)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // 生效项：浅强调底 + 圆角 12，落在卡片内（原型）。
        .background(isActive ? Theme.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, -8)
        .contextMenu { rowMenuItems(item) }
    }

    /// 用量条 + 「用量 / 总量 / 到期」：窄列时上下排（原型为条在上、文字在下）。
    @ViewBuilder
    private func usageRow(used: Int64, total: Int64, expiresAt: Date?) -> some View {
        let fraction = Double(used) / Double(total)
        VStack(alignment: .leading, spacing: 3) {
            usageBar(fraction)
                .frame(maxWidth: 280)
            usageDetail(used: used, total: total, expiresAt: expiresAt)
        }
        .padding(.top, 1)
    }

    private func usageBar(_ fraction: Double) -> some View {
        CapacityBar(fraction: fraction, tint: Theme.usageTint(fraction), height: 4)
            .accessibilityLabel("已用流量")
            .accessibilityValue("\(Int((min(fraction, 1) * 100).rounded()))%")
    }

    private func usageDetail(used: Int64, total: Int64, expiresAt: Date?) -> some View {
        // 0 是有效用量，格式化后为空串时要保留占位，否则「已用 / 总量」缺一半。
        var text = "\(Theme.bytesOrDash(used)) / \(Theme.bytesOrDash(total))"
        if let expiresAt {
            text += " / \(Self.compactDateFormatter.string(from: expiresAt)) 到期"
        }
        return Text(text)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// 「更新于 2026-11-09 00:20」：原型用 ISO 风格短日期，固定格式不随系统地区变。
    static let compactDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func rowSubtitle(_ item: AppState.ConfigItem) -> String {
        var parts = ["\(item.nodeCount) 个节点"]
        if let updated = item.lastUpdatedAt {
            parts.append("更新于 \(Self.compactDateFormatter.string(from: updated))")
        }
        return parts.joined(separator: " / ")
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
            Image(systemName: "ellipsis")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("\(item.name)的配置操作")
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

    /// 添加配置卡（原型右侧第一张）：输入框 + 导入，下方说明 + 添加自建节点。
    private var importBar: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("添加配置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Clash YAML 订阅链接")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    TextField("粘贴 Clash YAML 订阅链接", text: $subscriptionURL, prompt: Theme.inputPrompt("粘贴 Clash YAML 订阅链接"))
                        .font(.system(size: 12))
                        .inputField()
                        .onSubmit(beginImport)
                    Button("导入") { beginImport() }
                        .fixedSize()
                        .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack(alignment: .center, spacing: 12) {
                    Text("导入会下载订阅并校验配置")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("添加自建节点") { showingManualNode = true }
                        .controlSize(.small)
                        .fixedSize()
                }
            }
        }
    }

    /// 自动更新卡（原型右侧第二张）：图标块 + 标题 + 周期说明 + 更改。
    private var autoUpdateCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                IconTile(symbol: "arrow.clockwise", size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动更新")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(scheduleText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("更改…") { showsScheduleSheet = true }
                    .controlSize(.small)
                    .fixedSize()
            }
        }
    }

    private var selectedNodeTitle: String {
        guard let node = state.selectedNode else { return "未选择" }
        let code = state.nodeCatalog.metadataByNodeID[node.id]?.regionCode
            ?? NodeNameMetadata.parse(node.name).regionCode
        return MenuBarPanelDirectory.nodeTitle(node.name, regionCode: code ?? "")
    }

    /// 当前配置卡（原型右侧第三张）：展示生效配置概览与快捷入口。
    private var activeConfigCard: some View {
        GroupBox {
            if let config = state.configItems.first(where: { $0.id == state.activeConfigID }) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Text(config.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        StatusBadge(text: "当前配置", style: Theme.current)
                    }

                    LabeledContent("节点", value: "\(config.nodeCount) 个")
                    LabeledContent("策略组", value: "\(state.activeConfigPolicyGroups.count) 个")
                    LabeledContent("当前选择", value: selectedNodeTitle)
                    LabeledContent(
                        "最近更新",
                        value: config.lastUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未更新"
                    )

                    if let usage = config.usage, let used = usage.usedBytes, let total = usage.totalBytes, total > 0 {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("套餐用量", value: "\(Theme.bytesOrDash(used)) / \(Theme.bytesOrDash(total))")
                            CapacityBar(fraction: Double(used) / Double(total), tint: Theme.usageTint(Double(used) / Double(total)), height: 4)
                        }
                    }

                    if let expiresAt = config.usage?.expiresAt {
                        LabeledContent("到期日", value: Self.compactDateFormatter.string(from: expiresAt))
                    }

                    HStack(spacing: 8) {
                        Button("选择节点") { state.requestPage(.policyGroups) }
                            .controlSize(.small)
                        Button("查看日志") { state.requestPage(.records) }
                            .controlSize(.small)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            } else {
                TileEmptyNote(symbol: "square.stack.3d.up", text: "还没有生效配置")
                    .padding(.vertical, 16)
            }
        }
    }

    private var configSummary: String {
        "\(state.configItems.count) 个 / 生效：\(state.configItems.first { $0.id == state.activeConfigID }?.name ?? "无")"
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
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

            CardForm {
                CardSection {
                    LabeledContent("名称") {
                        TextField("名称", text: $name, prompt: Theme.inputPrompt(url.host ?? "订阅"))
                            .labelsHidden()
                            .inputField()
                            .frame(maxWidth: 240)
                    }
                    .disabled(isImporting)
                    Toggle("参与定时自动更新", isOn: $autoUpdate)
                        .disabled(isImporting)
                } footer: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let importError {
                            Label {
                                Text(importError)
                                    .foregroundStyle(Theme.danger.text)
                                    .textSelection(.enabled)
                            } icon: {
                                Image(systemName: "exclamationmark.octagon.fill")
                                    .foregroundStyle(Theme.danger.icon)
                            }
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Theme.separator.frame(height: 0.5)
            HStack {
                if isImporting {
                    ProgressView().controlSize(.small)
                    Text("正在下载并解析…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("导入") { beginImport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.pillProminent)
                    .disabled(isImporting)
            }
            .padding(16)
        }
        .frame(width: 440, height: 300)
        .tint(Theme.accent)
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
                .foregroundStyle(Theme.textPrimary)
            TextField("名称", text: $name, prompt: Theme.inputPrompt("名称"))
                .inputField()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onConfirm(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.pillProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .tint(Theme.accent)
        .onAppear { name = source.name }
    }
}
