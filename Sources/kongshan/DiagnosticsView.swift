import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 「诊断」页：出口 / 自检 / 命中 / 深度 四个分段。
///
/// 2026-09-17 之前，排查能力散在六处：出口分析（独立页）、网络自检与限时诊断（设置→网络）、
/// 规则命中测试（规则页折叠分区）、导出脱敏诊断（设置→更多）。
/// 「出问题时去哪」因此没有唯一答案——这一页就是那个答案。
///
/// **用 `.principal` 分段而不是四个 GroupBox 堆在一个滚动页里**：后者会让页面工具栏
/// （重新自测 / 刷新出口 / 复制报告）只对第一个分区有效，用户滚到第三个分区时
/// 工具栏仍显示与视野无关的按钮。分段切换后任意时刻只有一个子视图，工具栏归属明确。
struct DiagnosticsView: View {
    enum Tab: String, CaseIterable {
        case exit = "出口"
        case selfCheck = "自检"
        case routeTest = "命中"
        case deep = "深度"
    }

    @State private var tab: Tab = .exit

    var body: some View {
        // 结构化 switch：出口分析分段自带网络请求，常驻会让它在别的分段也跑。
        Group {
            switch tab {
            case .exit: ExitAnalysisView()
            case .selfCheck: NetworkSelfCheckView()
            case .routeTest: RouteHitTestView()
            case .deep: DeepDiagnosticsView()
            }
        }
        .navigationTitle("诊断")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("诊断项目", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

// MARK: - 本机网络自检

/// 迁自 设置→网络·网络自检与修复。
/// 它是「一次性动作 + 一份会长出来的报告」，不是可保存的配置——Form 不该承载这种模块，
/// 放在设置里也等于把「出问题去哪」的答案藏进了低频区。
struct NetworkSelfCheckView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Form {
            Section {
                Text("检查各网络服务是否残留 kongshan 的代理 / DNS 设置，清理后再验一次连通性。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let report = state.networkRepairReport {
                Section("检查结果") {
                    ForEach(report.items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(Theme.networkCheckTint(item.severity))
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout.weight(.medium))
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                if !report.services.isEmpty {
                    // 优先级是 2026-09-16 那次断网事故的要害：排在前面的服务出问题会拖垮整机解析，
                    // 而用户只会去看自己在用的那个（Wi-Fi）。这里把顺序摆出来。
                    Section("网络服务优先级（macOS 按此顺序选用 DNS）") {
                        ForEach(report.services) { svc in
                            HStack(spacing: 8) {
                                Text("\(svc.order)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)
                                Text(svc.name).font(.caption)
                                Spacer(minLength: 8)
                                Text(svc.dnsServers.isEmpty ? "DNS 未设置" : svc.dnsServers.joined(separator: " "))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            } else if !state.isRepairingNetwork {
                Section {
                    ContentUnavailableView {
                        Label("还没有自检", systemImage: "stethoscope")
                    } description: {
                        Text("检查接管残留、网络服务设置、残留内核进程与连通性，发现问题会就地修复。")
                    } actions: {
                        Button("开始自检") { Task { await state.runNetworkRepair() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await state.runNetworkRepair() }
                } label: {
                    Label("开始自检", systemImage: "stethoscope")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isRepairingNetwork)
                .help("检查并修复接管残留，然后验一次连通性（⌘R）")
            }
        }
        .overlay {
            if state.isRepairingNetwork {
                ProgressView("正在自检…").controlSize(.large)
            }
        }
    }

    private var subtitle: String {
        guard let report = state.networkRepairReport else { return "尚未自检" }
        return "\(report.summary) · 自检于 \(report.checkedAt.formatted(date: .omitted, time: .standard))"
    }
}

// MARK: - 规则命中测试

/// 迁自 规则页的 `routeTester` 折叠分区。
/// 它不改任何配置，只回答「为什么这条流量走了那里」——是诊断工具，不是规则。
struct RouteHitTestView: View {
    @Environment(AppState.self) private var state
    @State private var kind: RouteTestKind = .domain
    @State private var input = ""
    @State private var result: RouteTestResult?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                Picker("输入类型", selection: $kind) {
                    ForEach(RouteTestKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack(spacing: 10) {
                    // `prompt` 作占位、`labelsHidden` 去掉左侧常驻标签：在 Form(.grouped) 里
                    // `TextField("标题", text:)` 的标题会被当成左侧标签，可编辑区被挤到右边缘。
                    TextField(kind.placeholder, text: $input, prompt: Text(kind.placeholder))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .onSubmit(run)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Button("测试", action: run)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                }
            } footer: {
                Text("按实际生成顺序解释本地可判定的规则；订阅规则集按已下载的内容判定。GEOIP 与内置国内规则要靠内核的 IP 库，不参与。")
            }

            if let result {
                Section("命中结果") {
                    LabeledContent("来源") {
                        Label(result.source.rawValue, systemImage: "checkmark.seal.fill")
                    }
                    LabeledContent("优先级", value: "\(result.priority)")
                    LabeledContent("动作") {
                        Text(result.action.displayName)
                            .foregroundStyle(
                                result.action == .direct ? .green
                                    : result.action == .reject ? .red : Color.accentColor
                            )
                    }
                    LabeledContent("目标", value: result.target)
                    LabeledContent("命中", value: result.matchedValue)
                }
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(result == nil ? "输入一个目标看它会走哪里" : "命中 \(result!.target)")
        .onChange(of: kind) { _, _ in result = nil }
        .onChange(of: input) { _, _ in result = nil }
    }

    private func run() {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isTesting else { return }
        let kind = kind
        isTesting = true
        Task {
            // 规则集内容要从磁盘读（几万条），放在后台；读完时输入若已改动，结果作废。
            let tested = await state.testRoute(
                domain: kind == .domain ? value : nil,
                ip: kind == .ip ? value : nil,
                processName: kind == .process ? value : nil
            )
            isTesting = false
            guard input.trimmingCharacters(in: .whitespacesAndNewlines) == value, self.kind == kind else { return }
            result = tested
        }
    }
}

/// 非 private：`RouteHitTestView` 与规则页都用得到（规则页只留跳转按钮，但类型共享）。
enum RouteTestKind: String, CaseIterable, Identifiable {
    case domain
    case ip
    case process

    var id: Self { self }
    var title: String {
        switch self {
        case .domain: "域名"
        case .ip: "IP"
        case .process: "进程"
        }
    }
    var placeholder: String {
        switch self {
        case .domain: "api.example.com"
        case .ip: "203.0.113.8"
        case .process: "Safari"
        }
    }
}

// MARK: - 深度诊断

/// 迁自 设置→网络·限时诊断 与 设置→更多·数据与日志·故障诊断。
/// 这是排查动线的最后一步：开 Debug → 复现 → 导出发给维护者。两者挨着才形成闭环。
struct DeepDiagnosticsView: View {
    @Environment(AppState.self) private var state
    @State private var diagnosticDocument: TextExportDocument?
    @State private var showsExporter = false
    @State private var isPreparing = false
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                if state.isDiagnosticModeActive, let deadline = state.diagnosticModeEndsAt {
                    LabeledContent("内核输出级别", value: "Debug（临时）")
                    HStack {
                        Text("剩余")
                        Text(deadline, style: .timer).monospacedDigit()
                        Spacer()
                        Button("立即恢复") { Task { await state.disableDiagnosticMode() } }
                            .disabled(state.isBusy)
                    }
                } else {
                    LabeledContent("内核输出级别", value: "Info（普通）")
                    HStack {
                        Text("需要复现疑难网络问题时临时记录更多细节。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("开启 15 分钟") { Task { await state.enableDiagnosticMode() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isBusy || state.isTestingAllDelays)
                    }
                }
            } header: {
                Text("详细日志")
            } footer: {
                // 「内核输出级别」而不是「内核日志」：日志页有一个同名但语义不同的「显示等级」，
                // 那个只过滤已经收到的行。不区分就会出现「开了 Debug 却看不到 debug 行」的误解。
                Text("与日志页的「显示等级」不同：这里决定内核**产出**多详细的行，那里只过滤已收到的行。"
                     + "切换会重载内核并断开当前连接；到期自动恢复，截止时间随设置持久化。")
            }

            Section {
                HStack {
                    Text("打包配置、运行事件与最近日志，发给维护者时用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if isPreparing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("导出脱敏诊断…") { prepareExport() }
                    }
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("导出诊断包")
            } footer: {
                Text("导出前会脱敏：订阅地址、节点凭据与本机用户名都不会出现在文件里。")
            }
        }
        .formStyle(.grouped)
        .navigationSubtitle(state.isDiagnosticModeActive ? "详细日志已开启" : "按需开启详细日志")
        .fileExporter(
            isPresented: $showsExporter,
            document: diagnosticDocument,
            contentType: .plainText,
            defaultFilename: "kongshan-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                notice = "导出失败：\(error.localizedDescription)"
            } else {
                notice = "已导出诊断包。"
            }
            diagnosticDocument = nil
        }
    }

    private func prepareExport() {
        isPreparing = true
        notice = nil
        Task {
            defer { isPreparing = false }
            do {
                diagnosticDocument = TextExportDocument(text: try await state.exportDiagnostics())
                showsExporter = true
            } catch {
                notice = "准备诊断包失败：\(error.localizedDescription)"
            }
        }
    }
}
