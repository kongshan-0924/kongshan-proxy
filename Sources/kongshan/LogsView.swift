import Foundation
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

struct LogsView: View {
    @Environment(AppState.self) private var state
    @State private var pausesAutomaticScroll = false
    @State private var exportDocument: LogExportDocument?
    @State private var showsExporter = false
    @State private var isPreparingExport = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .navigationTitle("日志")
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
            Picker("日志等级", selection: logLevelBinding) {
                Text("信息").tag(CoreLogLevel.info)
                Text("警告").tag(CoreLogLevel.warning)
                Text("错误").tag(CoreLogLevel.error)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .disabled(!state.isOn)

            Toggle("暂停自动滚动", isOn: $pausesAutomaticScroll)
                .toggleStyle(.checkbox)

            Spacer()

            Text("\(state.liveLogs.count) / \(KernelLogStore.defaultBufferedLineLimit)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Button("清空显示") { state.clearLiveLogs() }
                .disabled(state.liveLogs.isEmpty)

            Button {
                prepareExport()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(isPreparingExport)
        }
        .padding()
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(state.liveLogs) { item in
                        LogEntryRow(item: item)
                            .id(item.id)
                        Divider()
                    }
                }
                .padding(.horizontal)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.35))
            .overlay {
                if state.liveLogs.isEmpty {
                    ContentUnavailableView(
                        state.isOn ? "等待内核日志" : "代理未启动",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(
                            state.isOn
                                ? "内核产生日志后将实时显示，内存最多保留 2000 行。"
                                : "开启代理后才会连接实时日志推送。"
                        )
                    )
                }
            }
            .onChange(of: state.liveLogs.count) {
                guard !pausesAutomaticScroll, let lastID = state.liveLogs.last?.id else { return }
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
                exportDocument = LogExportDocument(text: try await state.exportLogs())
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
                .foregroundStyle(.secondary)
            Text(levelTitle)
                .foregroundStyle(levelColor)
                .frame(width: 42, alignment: .leading)
            Text(item.entry.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.vertical, 5)
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

private struct LogExportDocument: FileDocument {
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
