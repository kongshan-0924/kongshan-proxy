import AppKit
import Foundation
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Environment(AppState.self) private var state
    @State private var pausesAutomaticScroll = false
    @State private var exportDocument: TextExportDocument?
    @State private var showsExporter = false
    @State private var isPreparingExport = false
    @State private var filterText = ""
    @State private var showsProblemsOnly = false
    @State private var groupsByConnection = false
    @State private var scrollToBottomTrigger = 0
    @State private var filterHovered = false

    private var filteredLogs: [LiveLogEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.liveLogs.filter { item in
            // 「只看问题」是排查时最先按的那一下：几千行里真正有信息量的通常只有几十行。
            if showsProblemsOnly {
                guard item.entry.level == .error || item.entry.level == .warning else { return false }
                guard !item.parsed.isExpectedRuleRejection else { return false }
            }
            guard !query.isEmpty else { return true }
            // 也匹配解析出的主机名：用户想查的通常是"某个域名怎么了"，
            // 而主机名在正文里的位置和写法各行不一，只匹配整行会漏。
            if item.entry.message.localizedCaseInsensitiveContains(query) { return true }
            return item.parsed.host?.localizedCaseInsensitiveContains(query) ?? false
        }
    }

    var body: some View {
        // 过滤只算一遍：日志每 200 ms 批量到达一次，body 跟着重算；filteredLogs 是对至多 2000 行的
        // 全量过滤（含不区分大小写的子串匹配），避免一次求值里被访问多次。
        let logs = filteredLogs
        let countText = "\(logs.count) / \(state.liveLogs.count) 行"
        return VStack(alignment: .leading, spacing: Theme.cardGap) {
            // 只有两个小窗：限 2 列平分宽度，宽窗口里不留空列。列宽下限 280：最小窗口（820 宽，内容约 592）
            // 也保持两列，否则两卡竖排把内核日志卡挤到只剩标题行（2026-11-09 最小窗口快照）。
            TileMasonry(minColumnWidth: 280, maxColumns: 2) {
                MessagesView(tab: .constant(.warnings))
                MessagesView(tab: .constant(.events))
            }
            .fixedSize(horizontal: false, vertical: true)

            kernelLogsCard(logs: logs, countText: countText)
        }
        .padding(Theme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvasBackground)
        .buttonStyle(.pill)
        // 原型取消了页面级底栏，原 PageStatusBar("\(countText) · 存档不受清除影响") 的统计信息与操作已直接置于内核日志卡底部
        .pageTopBar {
            TopBarSearchField(text: $filterText, prompt: "搜索日志或主机名", width: 220)
        }
        .onAppear { state.startLogMonitoring() }
        .onDisappear { state.stopLogMonitoring() }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: "kongshan-logs"
        ) { result in
            if case let .failure(error) = result {
                state.errorMessage = "导出日志失败：\(error.localizedDescription)"
            }
            exportDocument = nil
        }
    }

    private func kernelLogsCard(logs: [LiveLogEntry], countText: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                IconTile(symbol: "terminal", size: 22)
                CardHeader("内核日志", detail: countText) {
                    kernelTrailingActions
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if pausesAutomaticScroll {
                kernelFixedHeader
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            Theme.separator.frame(height: 0.5)

            if logs.isEmpty {
                VStack {
                    Spacer()
                    if !filterText.isEmpty {
                        TileEmptyNote(text: "未找到匹配「\(filterText)」的日志")
                    } else if state.isOn {
                        TileEmptyNote(text: "等待内核日志（内存最多保留 2000 行）")
                    } else {
                        TileEmptyNote(text: "代理未启动，开启代理后连接实时日志")
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // ScrollViewReader 必须在 ScrollView 外面：原先套在 LazyVStack 里面，懒加载栈把它当成一个子视图，
                // 2000 行日志全部当场建好——满载时切到日志页约 4 s、离开约 0.8 s（2026-11-09 iMac 基准）。
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            kernelLogRows(logs: logs)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.automatic)
                    .onChange(of: state.liveLogs.last?.id) {
                        guard !pausesAutomaticScroll, let lastID = lastRowID(logs) else { return }
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                    .onChange(of: scrollToBottomTrigger) {
                        if let lastID = lastRowID(logs) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Theme.separator.frame(height: 0.5)

            HStack {
                Text("\(logs.count) 行 / 存档不受清除影响")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("在访达中显示") {
                    state.revealArchivesInFinder()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }

    private var kernelTrailingActions: some View {
        HStack(spacing: 8) {
            CapsuleSegmentedPicker(
                options: [CoreLogLevel.info, .warning, .error],
                selection: logLevelBinding
            ) { level in
                switch level {
                case .info: "信息"
                case .warning: "警告"
                default: "错误"
                }
            }
            .fixedSize()
            .disabled(!state.isOn)
            .help("过滤显示的最低等级")

            Menu {
                Toggle("只看问题", isOn: $showsProblemsOnly)
                Toggle("按连接聚合", isOn: $groupsByConnection)
                Divider()
                Toggle("暂停自动滚动", isOn: $pausesAutomaticScroll)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: showsProblemsOnly || groupsByConnection
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(showsProblemsOnly || groupsByConnection ? Theme.accent : Theme.textSecondary)
                    Text("过滤")
                }
                .font(.caption)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(filterHovered ? Theme.hoverFill : Theme.cardFill, in: Capsule(style: .circular))
                .overlay(Capsule(style: .circular).strokeBorder(Theme.controlStroke, lineWidth: 1))
                .contentShape(Capsule(style: .circular))
                .onHover { filterHovered = $0 }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("只看问题 / 按连接聚合 / 暂停自动滚动")

            Button {
                state.clearLiveLogs()
            } label: {
                Label("清空显示", systemImage: "trash")
                    .labelStyle(.titleOnly)
            }
            .controlSize(.small)
            .keyboardShortcut("k", modifiers: .command)
            .disabled(state.liveLogs.isEmpty)
            .help("清空当前显示的日志，不影响磁盘上的日志文件")

            Button {
                prepareExport()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .labelStyle(.titleOnly)
            }
            .controlSize(.small)
            .disabled(isPreparingExport)
            .help("导出内核日志")
        }
    }

    @ViewBuilder
    private var kernelFixedHeader: some View {
        if pausesAutomaticScroll {
            HStack {
                Spacer()
                Button {
                    pausesAutomaticScroll = false
                    scrollToBottomTrigger += 1
                } label: {
                    Label("恢复自动滚动", systemImage: "play.circle.fill")
                        .font(.caption)
                }
                .controlSize(.small)
                .foregroundStyle(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private func kernelLogRows(logs: [LiveLogEntry]) -> some View {
            if logs.isEmpty {
                EmptyView()
            } else if groupsByConnection {
                let groups = LogConnectionGrouping.groups(from: logs)
                ForEach(groups) { group in
                    LogConnectionRow(group: group)
                        .id(group.id)
                    if group.id != groups.last?.id {
                        Theme.separator.frame(height: 0.5)
                    }
                }
            } else {
                ForEach(logs) { item in
                    LogEntryRow(item: item)
                        .id(item.id)
                        .contextMenu {
                            Button("复制消息") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.entry.message, forType: .string)
                            }
                        }
                    if item.id != logs.last?.id {
                        Theme.separator.frame(height: 0.5)
                    }
                }
            }
    }

    /// 最后一行的标识。按连接聚合时行是分组（id 为连接 ID），用条目 id 去 scrollTo 对不上任何行。
    private func lastRowID(_ logs: [LiveLogEntry]) -> AnyHashable? {
        if groupsByConnection {
            return LogConnectionGrouping.groups(from: logs).last.map { AnyHashable($0.id) }
        }
        return logs.last.map { AnyHashable($0.id) }
    }

    private var logLevelBinding: Binding<CoreLogLevel> {
        Binding(
            get: { state.logLevel },
            set: { level in state.setLogLevel(level) }
        )
    }

    private func prepareExport() {
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            do {
                exportDocument = TextExportDocument(text: try await state.exportLogs())
                showsExporter = true
            } catch {
                state.errorMessage = "准备日志导出失败：\(error.localizedDescription)"
            }
        }
    }
}

enum LogConnectionGrouping {
    static let transitionWindow: TimeInterval = 30

    static func groups(from logs: [LiveLogEntry]) -> [LogConnectionGroup] {
        var order: [String] = []
        var buckets: [String: [LiveLogEntry]] = [:]
        var hosts: [String: String] = [:]

        let transitionBuckets = Set(logs.lazy.compactMap { item -> Int64? in
            guard item.parsed.isNetworkTransitionFailure else { return nil }
            return timeBucket(for: item.entry.receivedAt)
        })

        for item in logs {
            let parsed = item.parsed
            let bucket = timeBucket(for: item.entry.receivedAt)
            let isProblem = item.entry.level == .error || item.entry.level == .warning
            let isDuringTransition = isProblem && transitionBuckets.contains(bucket)
            // 同一 30 秒窗口内的派生错误合成一次网络切换事件；其余仍按连接 ID 聚合。
            let key = isDuringTransition ? "network-transition-\(bucket)" : parsed.connectionID ?? "sys-\(item.id)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
            if isDuringTransition {
                hosts[key] = "网络切换期间"
            } else if hosts[key] == nil, let host = parsed.host {
                hosts[key] = host
            }
        }

        return order.map { key in
            let entries = buckets[key] ?? []
            return LogConnectionGroup(
                id: key,
                host: hosts[key],
                entries: entries,
                worstLevel: diagnosticLevel(for: entries)
            )
        }
    }

    private static func timeBucket(for date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSinceReferenceDate / transitionWindow))
    }

    private static func diagnosticLevel(for entries: [LiveLogEntry]) -> CoreLogLevel {
        let problems = entries.filter { !$0.parsed.isExpectedRuleRejection }
        if problems.contains(where: { $0.entry.level == .error }) { return .error }
        if problems.contains(where: { $0.entry.level == .warning }) { return .warning }
        return .info
    }
}

private struct LogEntryRow: View {
    let item: LiveLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.entry.receivedAt, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Text(levelTitle)
                .font(.caption.weight(.medium).monospaced())
                .foregroundStyle(levelStyle.text)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(levelStyle.soft, in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 52, alignment: .leading)
            Text(item.entry.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 4)
    }

    private var levelTitle: String {
        switch item.entry.level {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }

    /// DEBUG / INFO 退回中性，只有 WARN / ERROR 占用语义浅底。
    private var levelStyle: Theme.SemanticColors {
        switch item.entry.level {
        case .debug, .info: Theme.neutral
        case .warning: Theme.warning
        case .error: Theme.danger
        }
    }
}

struct TextExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            text = ""
            return
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 一条连接的日志组。
struct LogConnectionGroup: Identifiable {
    let id: String
    let host: String?
    let entries: [LiveLogEntry]
    let worstLevel: CoreLogLevel
}

/// 折叠的连接组。默认收起，只显示"目标主机 + 几行 + 最坏级别"；
/// 展开才铺开完整链路。排查时先扫一眼哪组是红的，再点开那一组。
private struct LogConnectionRow: View {
    let group: LogConnectionGroup
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 10)
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                    Text(group.host ?? "（无目标主机）")
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text("\(group.entries.count) 行")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("复制整条链路") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        group.entries.map(\.entry.message).joined(separator: "\n"),
                        forType: .string
                    )
                }
            }

            if isExpanded {
                ForEach(group.entries) { item in
                    LogEntryRow(item: item)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private var tint: Color {
        switch group.worstLevel {
        case .error: Theme.danger.icon
        case .warning: Theme.warning.icon
        default: Theme.neutral.icon
        }
    }
}
