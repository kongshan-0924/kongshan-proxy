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

    private var filteredLogs: [LiveLogEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return state.liveLogs.filter { item in
            // 「只看问题」是排查时最先按的那一下：几千行里真正有信息量的通常只有几十行。
            if showsProblemsOnly, item.entry.level != .error, item.entry.level != .warning {
                return false
            }
            guard !query.isEmpty else { return true }
            // 也匹配解析出的主机名：用户想查的通常是"某个域名怎么了"，
            // 而主机名在正文里的位置和写法各行不一，只匹配整行会漏。
            if item.entry.message.localizedCaseInsensitiveContains(query) { return true }
            return CoreLogLine.parse(item.entry.message).host?.localizedCaseInsensitiveContains(query) ?? false
        }
    }

    /// 按连接 ID 聚合。同一条连接的多行日志（入站 → 进程匹配 → 出站 → 失败原因）
    /// 本来就是一个整体，散在几千行里靠肉眼找同号行是这一页最不好用的地方。
    private var connectionGroups: [LogConnectionGroup] {
        var order: [String] = []
        var buckets: [String: [LiveLogEntry]] = [:]
        var hosts: [String: String] = [:]

        for item in filteredLogs {
            let parsed = CoreLogLine.parse(item.entry.message)
            // 没有连接 ID 的行（内核启动、DNS 缓存之类）单独成组，不能丢。
            let key = parsed.connectionID ?? "sys-\(item.id)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(item)
            if hosts[key] == nil, let host = parsed.host { hosts[key] = host }
        }

        return order.map { key in
            let entries = buckets[key] ?? []
            return LogConnectionGroup(
                id: key,
                host: hosts[key],
                entries: entries,
                // 一组里只要有错就整组标红：那才是需要展开细看的组。
                worstLevel: entries.contains { $0.entry.level == .error } ? .error
                    : entries.contains { $0.entry.level == .warning } ? .warning : .info
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "内核日志", subtitle: "代理运行时实时订阅内核推送") {
                HStack(spacing: 8) {
                    Button("清空显示") { state.clearLiveLogs() }
                        .disabled(state.liveLogs.isEmpty)
                    Button {
                        prepareExport()
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                    }
                    .disabled(isPreparingExport)
                }
            }
            toolbar
            Divider()
            logList
        }
        .pageBackground()
        .navigationTitle("内核日志")
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            // 这个选择器只是"过滤内核推来的日志"，不改内核自己的 log.level（那要重启内核）。
            // 内核按 info 输出，因此没有「调试」这一档可选——放上去只会是个点了没反应的死控件。
            Picker("日志等级", selection: logLevelBinding) {
                Text("信息").tag(CoreLogLevel.info)
                Text("警告").tag(CoreLogLevel.warning)
                Text("错误").tag(CoreLogLevel.error)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 180)
            .disabled(!state.isOn)

            SearchField(text: $filterText, placeholder: "搜索日志关键词…")
                .frame(maxWidth: 220)

            Toggle("只看问题", isOn: $showsProblemsOnly)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("只显示警告与错误")

            Toggle("按连接聚合", isOn: $groupsByConnection)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("把同一条连接的多行日志折成一组，点开看完整链路")

            Toggle("暂停自动滚动", isOn: $pausesAutomaticScroll)
                .toggleStyle(.checkbox)
                .font(.caption)

            Spacer()

            Text("\(filteredLogs.count) / \(state.liveLogs.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if groupsByConnection {
                        ForEach(connectionGroups) { group in
                            LogConnectionRow(group: group)
                                .id(group.id)
                            Divider().opacity(0.4)
                        }
                    } else {
                        ForEach(filteredLogs) { item in
                            LogEntryRow(item: item)
                                .id(item.id)
                                .contextMenu {
                                    Button("复制消息") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.entry.message, forType: .string)
                                    }
                                }
                            Divider().opacity(0.4)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if filteredLogs.isEmpty {
                    ContentUnavailableView(
                        filterText.isEmpty ? (state.isOn ? "等待内核日志" : "代理未启动") : "未匹配到相关日志",
                        systemImage: filterText.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass",
                        description: Text(
                            filterText.isEmpty
                                ? (state.isOn ? "内核产生日志后将实时显示，内存最多保留 2000 行。" : "开启代理后才会连接实时日志推送。")
                                : "请尝试搜索其他关键字。"
                        )
                    )
                }
                if pausesAutomaticScroll {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                pausesAutomaticScroll = false
                                if let lastID = filteredLogs.last?.id {
                                    withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                                }
                            } label: {
                                Label("回到底部", systemImage: "arrow.down.circle.fill")
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 24)
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
            .onChange(of: state.liveLogs.count) {
                guard !pausesAutomaticScroll, let lastID = filteredLogs.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
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

private struct LogEntryRow: View {
    let item: LiveLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.entry.receivedAt, format: .dateTime.hour().minute().second())
                .foregroundStyle(.tertiary)
            Text(levelTitle)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(levelColor)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(levelColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 4))
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

    private var levelColor: Color {
        switch item.entry.level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
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
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
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
                        .foregroundStyle(.tertiary)
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
        case .error: .red
        case .warning: .orange
        default: .secondary
        }
    }
}
