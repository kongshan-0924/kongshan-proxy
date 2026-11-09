import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 「诊断」页：一页看全的小窗布局（2026-11-06 由四段切换合并而来）。
///
/// 2026-09-17 之前，排查能力散在六处：出口分析（独立页）、网络自检与限时诊断（设置→网络）、
/// 规则命中测试（规则页折叠分区）、导出脱敏诊断（设置→更多）。
/// 「出问题时去哪」因此没有唯一答案——这一页就是那个答案。
///
/// 2026-11-06 再改：四段切换让没检测时整页只剩一张空卡，分段控件又把标题顶歪。
/// 合并成一页小窗后出口 / 自检 / 命中 / 导出各居其位，空态在小窗内占位，空间用满。
struct DiagnosticsView: View {
    /// 四段切换已合并成一页，枚举不再驱动界面；
    /// 保留是因为 `SidebarShortcutTests` 锚定「出口仍是诊断页的一部分」（`case exit` 字样）。
    enum Tab: String, CaseIterable {
        case exit = "出口"
        case selfCheck = "网络自检"
        case routeTest = "规则命中"
        case deep = "日志与导出"
    }

    @Environment(AppState.self) private var state

    var body: some View {
        TilePage {
            TileMasonry(minColumnWidth: 320, maxColumns: 2) {
                ExitAnalysisView()
                SiteReachabilityCard()
                RouteHitTestCard()
                NetworkSelfCheckCard()
                DeepDiagnosticsCard()
            }
        }
        // 原出口分段的两个动作整页通用，随合并挪到这里。
        .pageTopBar {
                Button {
                    ExitAnalysisView.runFullCheck(state: state)
                } label: {
                    Label("全部重新检测", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isRefreshingExitDiagnostics || state.isProbingSites)
                .help("重新检测出口 IP、DNS 与站点可达性")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ExitAnalysisView.plainTextReport(state: state), forType: .string)
                } label: {
                    Label("复制报告", systemImage: "doc.on.doc")
                }
                .help("复制成纯文本，便于反馈问题时贴出来")
        }
        // 原出口分段的进场自检：代理已开但还没测过时补一次出口检测。
        .onAppear {
            if state.isOn, state.exitDiagnostics == nil {
                Task { await state.refreshExitDiagnostics() }
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
        TilePage {
            TileMasonry(minColumnWidth: 300) {
                NetworkSelfCheckCard()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if state.networkRepairReport != nil { PageStatusBar(subtitle) }
        }
        .pageTopBar {
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

    private var subtitle: String {
        guard let report = state.networkRepairReport else { return "尚未自检" }
        return "\(report.summary) · 自检于 \(report.checkedAt.formatted(date: .omitted, time: .standard))"
    }
}

/// 「网络自检」小窗：诊断页第二排与独立页共用。
/// 「网络服务优先级」是同小窗里的第二段——顺序影响全机 DNS 解析，跟着自检结果一起看到才顺。
struct NetworkSelfCheckCard: View {
    @Environment(AppState.self) private var state

    var body: some View {
        TileCard(
            "网络自检", symbol: "stethoscope",
            detail: state.networkRepairReport?.summary,
            height: nil
        ) {
            Button {
                Task { await state.runNetworkRepair() }
            } label: {
                Label("开始自检", systemImage: "stethoscope")
            }
            .buttonStyle(.pillProminent)
            .disabled(state.isRepairingNetwork)
            // 合并页里 ⌘R 是「全部重新检测」，这里不再提快捷键，避免误导。
            .help("检查并修复接管残留，然后验一次连通性")
        } fixedHeader: {
            Text("检查接管残留、服务设置与连通性。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .help("检查各网络服务是否残留 kongshan 的代理 / DNS 设置，清理后再验一次连通性；发现问题会就地修复。")
        } content: {
            if let report = state.networkRepairReport {
                ForEach(report.items) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(networkCheckStyle(item.severity).icon)
                            .frame(width: 7, height: 7)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.callout)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(item.detail)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(item.detail)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 7)
                    if item.id != report.items.last?.id {
                        Theme.separator.frame(height: 0.5)
                    }
                }

                if !report.services.isEmpty {
                    Text("网络服务优先级")
                        .font(.callout.weight(.medium))
                        .padding(.top, 10)
                    Text("macOS 按此顺序选用 DNS")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.bottom, 4)
                    // 服务顺序会影响全机 DNS 解析；保留完整列表并在小窗内滚动。
                    ForEach(report.services) { svc in
                        TileRow(
                            symbol: "network", svc.name,
                            subtitle: svc.dnsServers.isEmpty ? "DNS 未设置" : svc.dnsServers.joined(separator: " "),
                            subtitleMonospaced: !svc.dnsServers.isEmpty,
                            showsDivider: svc.id != report.services.last?.id
                        ) {
                            Text("\(svc.order)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            } else if state.isRepairingNetwork {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在自检并复核连通性…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 20)
            } else {
                TileEmptyNote(text: "还没有自检")
            }
        }
    }

    private func networkCheckStyle(_ severity: NetworkCheckSeverity) -> Theme.SemanticColors {
        switch severity {
        case .ok: Theme.success
        case .fixed: Theme.warning
        case .problem: Theme.danger
        }
    }
}

// MARK: - 规则命中测试

/// 迁自 规则页的 `routeTester` 折叠分区。
/// 它不改任何配置，只回答「为什么这条流量走了那里」——是诊断工具，不是规则。
struct RouteHitTestView: View {
    var body: some View {
        TilePage {
            TileMasonry(minColumnWidth: 300) {
                RouteHitTestCard()
            }
        }
        .pageTopBar {}
    }
}

/// 「规则命中测试」小窗：诊断页第三排与独立页共用。
/// 原「测试」「命中结果」两张小窗合并成一张：控件在 fixedHeader 不滚动，结果在下面列表里。
struct RouteHitTestCard: View {
    @Environment(AppState.self) private var state
    @State private var kind: RouteTestKind = .domain
    @State private var input = ""
    @State private var result: RouteTestResult?
    @State private var isTesting = false

    var body: some View {
        TileCard("规则命中测试", symbol: "scope", height: nil) {
            // 标题行右侧留空：分段控件放标题行会把标题顶歪（2026-11-06 用户截图）。
            EmptyView()
        } fixedHeader: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("输入域名或 IP，测试命中哪条规则", text: $input, prompt: Theme.inputPrompt("输入域名或 IP，测试命中哪条规则"))
                        .labelsHidden()
                        .inputField()
                        .font(.body.monospaced())
                        .onSubmit(run)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                    Button("测试", action: run)
                        .buttonStyle(.pill)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTesting)
                }

                CapsuleSegmentedPicker(options: RouteTestKind.allCases, selection: $kind) { $0.title }
                    .fixedSize()
            }
        } content: {
            if let result {
                TileRow(symbol: "checkmark.seal.fill", "来源", subtitle: result.source.rawValue, showsDivider: true)
                TileRow(symbol: "list.number", "优先级", subtitle: "\(result.priority)", subtitleMonospaced: true, showsDivider: true)
                TileRow(symbol: "arrow.triangle.branch", "动作", showsDivider: true) {
                    Text(result.action.displayName)
                        .font(.callout)
                        .foregroundStyle(
                            result.action == .direct ? Theme.success.text
                                : result.action == .reject ? Theme.danger.text : Theme.textPrimary
                        )
                }
                TileRow(symbol: "point.topleft.down.to.point.bottomright.curvepath", "目标", subtitle: result.target, subtitleMonospaced: true, showsDivider: true)
                TileRow(symbol: "scope", "命中", subtitle: result.matchedValue, subtitleMonospaced: true, showsDivider: false)
            } else {
                TileEmptyNote(text: isTesting ? "正在匹配规则…" : "输入域名、IP 或进程名后测试")
            }
        }
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

    var body: some View {
        TilePage {
            TileMasonry(minColumnWidth: 300) {
                DeepDiagnosticsCard()
            }
        }
        .pageTopBar {}
    }
}

/// 「日志与导出」小窗：诊断页第三排与独立页共用。
/// 限时诊断与导出诊断合在一张随内容高的小窗里，中间一条分隔线分两段。
struct DeepDiagnosticsCard: View {
    @Environment(AppState.self) private var state
    @State private var diagnosticDocument: TextExportDocument?
    @State private var showsExporter = false
    @State private var isPreparing = false
    @State private var exportsShareable = false
    @State private var notice: String?

    var body: some View {
        TileCard("日志与导出", symbol: "square.and.arrow.up", height: nil) {
            // 第一段：限时诊断。
            if state.isDiagnosticModeActive, let deadline = state.diagnosticModeEndsAt {
                TileRow(symbol: "ladybug", "内核输出级别", subtitle: "Debug（临时）", showsDivider: true)
                TileRow(symbol: "timer", "剩余", showsDivider: false) {
                    DiagnosticCountdown(deadline: deadline)
                }
                Label {
                    Text("切换会重载内核并断开当前连接。")
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning.icon)
                }
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 8)
                Button("立即恢复") { Task { await state.disableDiagnosticMode() } }
                    .buttonStyle(.pill)
                    .disabled(state.isBusy)
                    .padding(.bottom, 8)
            } else {
                TileRow(symbol: "text.alignleft", "内核输出级别", subtitle: "Info（普通）", showsDivider: false)
                Text("临时记录更多细节，15 分钟后自动恢复。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    .help("这里决定内核产出多详细的行，与日志页只过滤已收到行的「显示等级」不同；截止时间随设置持久化，到期自动恢复。")
                Label {
                    Text("开启会重载内核并断开当前连接。")
                        .foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning.icon)
                }
                .font(.caption)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
                Button("开启 15 分钟") { Task { await state.enableDiagnosticMode() } }
                    .buttonStyle(.pill)
                    .disabled(state.isBusy || state.isTestingAllDelays)
                    .padding(.bottom, 8)
            }

            Theme.separator.frame(height: 0.5)
                .padding(.vertical, 6)

            // 第二段：导出诊断。
            Text("导出诊断")
                .font(.callout.weight(.medium))
                .padding(.vertical, 2)
            Text("打包配置、运行事件与最近日志。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.vertical, 8)
                .help("两版都不含订阅地址、节点凭据与本机用户名。完整版保留内核日志、节点服务器地址和规则，只发给信任的人；可公开分享版隐去这些信息。")
            Text("两版都不含订阅地址、节点凭据与本机用户名。完整版保留内核日志、节点服务器地址和规则，只发给信任的人；可公开分享版隐去这些信息。")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
            if isPreparing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在准备诊断包…")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 12)
            } else {
                HStack(spacing: 8) {
                    Button("完整版…") { prepareExport(forSharing: false) }
                        .help("含内核日志、节点地址与规则，只发给信任的人")
                    Button("可分享版…") { prepareExport(forSharing: true) }
                        .help("不含内核日志，隐去节点地址、规则内容、DNS 服务器、IP 与节点名")
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
            }
        }
        // 导出面板挂在小窗上：独立页与合并页共用同一张小窗，面板跟着状态走。
        .fileExporter(
            isPresented: $showsExporter,
            document: diagnosticDocument,
            contentType: .plainText,
            defaultFilename: exportsShareable ? "kongshan-diagnostics-shareable" : "kongshan-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                notice = "导出失败：\(error.localizedDescription)"
            } else {
                notice = "已导出诊断包。"
            }
            diagnosticDocument = nil
        }
    }

    private func prepareExport(forSharing: Bool) {
        isPreparing = true
        exportsShareable = forSharing
        notice = nil
        Task {
            defer { isPreparing = false }
            do {
                diagnosticDocument = TextExportDocument(text: try await state.exportDiagnostics(forSharing: forSharing))
                showsExporter = true
            } catch {
                notice = "准备诊断包失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 倒计时每秒变化；隔离到叶子视图，避免两张诊断小窗跟着每秒重建。
private struct DiagnosticCountdown: View {
    let deadline: Date

    var body: some View {
        Text(deadline, style: .timer)
            .font(.callout.monospacedDigit())
            .foregroundStyle(Theme.textPrimary)
    }
}
