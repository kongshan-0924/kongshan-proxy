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

    private var filteredLogs: [LiveLogEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return state.liveLogs }
        return state.liveLogs.filter { $0.entry.message.localizedCaseInsensitiveContains(query) }
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
                let logs = filteredLogs
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(logs) { item in
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
