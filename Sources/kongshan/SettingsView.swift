import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置

/// 2026-09-17 信息架构重构：5 分区 → 4 分区。
/// - 「隧道」原先混了三类（运行时开关 / 路由规则 / 系统集成）→ 拆：开关去仪表盘、
///   绕过列表去规则页、只留「接管」相关的 TUN 参数与免密码助手。
/// - 「网络」原先混了测速与两个诊断工具 → 测速去代理页、诊断去诊断页，只留 DNS。
/// - 「资源」整个取消：订阅自动更新去配置页、规则集数据库去规则页。
/// - 「更多」这个没有语义的杂物间改名「维护」。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case takeover
    case network
    case maintenance

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .takeover: "接管"
        case .network: "网络"
        case .maintenance: "维护"
        }
    }
}

/// 非 private：`RenderSnapshotTests` 要单独渲染这一页。设置页是全应用最长的表单，
/// 只经由 `MainWindowView` 间接覆盖的话，改布局时看不出它哪里塌了。
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var dnsDraft = DNSSettings.defaults
    @State private var testURLDraft = ""
    @State private var tunDraft = TunSettings.defaults
    @State private var tab: SettingsTab

    /// `initialTab` 只为离屏快照而设：设置页有五个分区，而 `tab` 是 @State，
    /// 外部无法指定，于是除「通用」外的四个分区从来没有被渲染验证过。
    init(initialTab: SettingsTab = .general) {
        _tab = State(initialValue: initialTab)
    }
    @State private var backupDocument: BackupDocument?
    @State private var showsBackupExporter = false
    @State private var showsBackupImporter = false
    @State private var isPreparingBackup = false
    @State private var backupNotice: String?
    @State private var diagnosticDocument: TextExportDocument?
    @State private var showsDiagnosticExporter = false
    @State private var isPreparingDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                // 四个分区各回答一个问题：通用＝这个 App 本身；接管＝它怎么接管系统；
                // 网络＝域名怎么解析；维护＝磁盘上的东西。
                // 运行时开关（系统代理 / TUN / 出站模式 / 局域网共享）一个都不在这里——
                // 它们的归属是仪表盘与连接页，设置页只放几个月才碰一次的东西。
                if tab == .general {
                Section("外观") {
                    Picker("菜单栏图标", selection: menuBarIconStyleBinding) {
                        ForEach(MenuBarIconStyle.allCases) { style in
                            // 直接把三种图标画出来给用户挑，比只列名字直观得多。
                            Label {
                                Text(style.displayName)
                            } icon: {
                                Image(nsImage: MenuBarIcon.image(style: style, state: .systemProxy))
                            }
                            .tag(style)
                        }
                    }
                    Text(state.menuBarIconStyle.summary + "。菜单栏会把图标染成单色，所以状态靠形状区分：关闭时是线稿、开启后填实、TUN 额外加一个点。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("开机自启") {
                    Toggle("登录时启动 kongshan", isOn: launchAtLoginBinding)
                        .disabled(
                            !state.isReady
                                || state.loginItemStatus == .requiresApproval
                                || state.loginItemStatus == .unsupported
                        )
                    LabeledContent("登录项状态", value: loginItemStatusTitle)
                    Toggle("登录后自动恢复上次的接管", isOn: autoRestoreBinding)
                        .disabled(!state.isReady || state.loginItemStatus != .enabled)
                    Text("仅在开机自启场景生效：登录后若上次是开着系统代理，会等网络就绪再自动开启；网络不可达或启动失败时不接管，并发系统通知告知。当前版本不自动恢复 TUN——它在助手需要重装时会弹管理员密码框，届时会跳过并在消息页留下记录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state.loginItemStatus == .requiresApproval {
                        Text("登录项已登记，但需要你在系统设置中批准。应用不会重复发起注册。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开系统登录项设置") {
                            Task { await state.openLoginItemSystemSettings() }
                        }
                    } else if state.loginItemStatus == .unsupported {
                        Text("当前运行环境不是可注册的应用包；请从打包后的 kongshan.app 使用此功能。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer()
                        Button("刷新状态") {
                            Task { await state.refreshLoginItemStatus() }
                        }
                        .disabled(!state.isReady)
                    }
                }

                Section("关于") {
                    LabeledContent("应用版本", value: Self.appVersion)
                    LabeledContent("应用更新") {
                        Button("查看最新版本") {
                            if let url = URL(string: "https://github.com/kongshan-0924/kongshan-proxy/releases/latest") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                    LabeledContent("内核") {
                        HStack(spacing: 8) {
                            // coreVersion 是内核 /version 的原样返回，已经带名字（`sing-box 1.13.14`）。
                            // 再加前缀会显示成「sing-box sing-box 1.13.14」。
                            Text(state.coreVersion)
                                .foregroundStyle(.secondary)
                            Button(state.isCheckingKernelUpdate ? "检查中…" : "检查内核更新") {
                                Task { await state.updateKernel() }
                            }
                            .controlSize(.small)
                            .disabled(state.isCheckingKernelUpdate)
                        }
                    }
                }
                }

                if tab == .takeover {
                Section {
                    Toggle("严格路由（strict_route）", isOn: strictRouteBinding)
                        .disabled(state.isBusy || !state.isReady)
                } header: {
                    Text("TUN")
                } footer: {
                    Text(tunFooterText)
                }

                Section("免密码助手") {
                    LabeledContent("状态", value: helperStatusText)
                    Text("免密码助手让 TUN 启停无需每次输入密码：安装需一次管理员授权，之后开机自动运行。未装时 TUN 仍可用（每次弹密码）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if state.helperInstallStatus == .needsReinstall {
                        // 本项目是 ad-hoc 签名，助手只能靠钉死 App 的 cdhash 来认人，
                        // 因此 App 一更新（cdhash 变）助手就必须重装一次。说清楚，别让用户以为坏了。
                        Text("助手在，但不认识当前这个 App —— 通常是 App 更新过（签名变了），或 App 被移动过位置。点「重新安装」授权一次即可，之后继续零弹窗。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    // 安装/卸载都要 bootout helper：TUN 正在跑时做这件事会把 root 内核变成
                    // 孤儿（继续持有 utun/路由/DNS，App 停不掉）。TUN 运行期间一律禁用。
                    if tunActive {
                        Text("TUN 正在运行，安装/卸载助手已暂时禁用——请先关闭 TUN，避免残留无法清理的 root 内核。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        if state.isHelperOperationInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        switch state.helperInstallStatus {
                        case .notInstalled:
                            Button("安装免密码助手") {
                                Task { await state.installHelper() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHelperOperationInProgress || tunActive)
                        case .installed:
                            Button("卸载") {
                                Task { await state.uninstallHelper() }
                            }
                            .disabled(state.isHelperOperationInProgress || tunActive)
                        case .needsReinstall:
                            Button("重新安装") {
                                Task { await state.installHelper() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(state.isHelperOperationInProgress || tunActive)
                        }
                    }
                }
                }

                if tab == .network {
                Section("DNS 高级设置") {
                    TextField("国内 DoH", text: $dnsDraft.domesticDoH)
                    TextField("远程 DoH", text: $dnsDraft.remoteDoH)
                    TextField("引导解析器（可选）", text: $dnsDraft.bootstrapResolver)
                    Text("geosite-cn 使用国内 DoH 直连解析，其余域名走当前代理的远程 DoH。兼容性优先，默认不启用 fake-ip。系统代理模式只管理进入本地 mixed 代理的解析，不等同于接管 macOS 全局 DNS。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("引导解析器负责解析出站节点自身的域名，必须是无连接的 UDP。留空时跟随国内 DoH 的地址；填入独立 IP（如 114.114.114.114）可与国内 DoH 解耦，避免一台上游抖动同时影响节点域名与国内域名解析。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("恢复默认") { dnsDraft = .defaults }
                        Button("放弃修改") { dnsDraft = state.dnsSettings }
                            .disabled(dnsDraft == state.dnsSettings)
                        Spacer()
                        Button("应用 DNS") {
                            Task {
                                await state.applyDNSSettings(dnsDraft)
                                dnsDraft = state.dnsSettings
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || !state.isReady || dnsDraft == state.dnsSettings)
                    }
                }

                Section("内网 DNS 分流") {
                    Toggle("把内网域名交给内网 DNS 解析", isOn: lanDNSEnabledBinding)
                        .disabled(state.isBusy || !state.isReady)

                    LabeledContent("自动探测到的 DNS", value: detectedLANServersText)
                    LabeledContent("自动探测到的域名", value: detectedLANDomainsText)

                    TextField("内网 DNS 服务器（留空＝用自动探测）", text: $tunDraft.lanDNSServer)
                        .disabled(!state.tunSettings.lanDNSEnabled || state.isBusy || !state.isReady)

                    Text("关掉它，内网域名会落到 Fake-IP 拿到一个 240.x 假地址，然后整段被路由进代理出口——表现就是内网设备一直加载。探测在接管系统 DNS 之前进行；网络不下发搜索域时，用下面的列表手填内网域名后缀。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                BypassListSection(
                    title: "内网域名后缀",
                    placeholder: "例如 corp.example.com 或 *.corp.example.com",
                    addTitle: "添加内网域名",
                    deleteHelp: "删除内网域名",
                    identity: "lan-domain",
                    values: $tunDraft.lanDomainSuffixes
                )

                Section {
                    HStack {
                        if tunDraft != state.tunSettings {
                            StatusBadge(text: "未应用", tint: .orange)
                        }
                        Spacer()
                        Button("应用内网 DNS 设置") {
                            Task { await state.applyTunSettings(tunDraft) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isBusy || tunDraft == state.tunSettings)
                    }
                } footer: {
                    Text("改动会重载内核并断开当前连接。")
                }
                }

                if tab == .maintenance {
                Section("备份与恢复") {
                    HStack {
                        Button {
                            prepareBackupExport()
                        } label: {
                            Label("导出配置与设置", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isPreparingBackup)

                        Button {
                            showsBackupImporter = true
                        } label: {
                            Label("导入备份", systemImage: "square.and.arrow.down")
                        }
                        .disabled(state.isOn || state.isBusy)

                        if isPreparingBackup { ProgressView().controlSize(.small) }
                        Spacer()
                        if let backupNotice {
                            StatusBadge(text: backupNotice, tint: .green)
                        }
                    }
                    Text("备份包含订阅链接、订阅配置快照、节点凭据和全部设置，可能含敏感信息；不包含日志、运行时密钥或恢复文件。导入前需先停止代理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("数据与日志") {
                    LabeledContent("故障诊断") {
                        Button {
                            prepareDiagnosticExport()
                        } label: {
                            Label("导出脱敏诊断", systemImage: "stethoscope")
                        }
                        .disabled(isPreparingDiagnostics)
                    }
                    LabeledContent("数据目录") {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([state.supportDirectory])
                        }
                    }
                    LabeledContent("日志目录") {
                        Button("在 Finder 中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([
                                state.supportDirectory.appending(path: "logs", directoryHint: .isDirectory)
                            ])
                        }
                    }
                    Text(state.supportDirectory.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("脱敏诊断不包含订阅原文、节点凭据或运行时密钥；日志仍可能包含访问域名和服务器地址，请仅发给可信维护者。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("清理") {
                    LabeledContent("清理缓存", value: state.cacheSizeBytes > 0 ? AppState.formatBytes(state.cacheSizeBytes) : "—")
                    Button("执行清理") {
                        Task { await state.clearRegenerableCaches() }
                    }
                    .disabled(state.isOn || state.isBusy || state.cacheSizeBytes == 0)
                    Text("删除内核日志与规则集缓存，两者都会自动重新生成。设置、订阅缓存和节点不受影响。需先停止内核。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .task { await state.refreshCacheSize() }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle("设置")
        .navigationSubtitle(tab.title)
        .toolbar {
            // 分区切换放工具栏正中：访达的视图切换器就在这个位置。
            ToolbarItem(placement: .principal) {
                Picker("分区", selection: $tab) {
                    ForEach(SettingsTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .onAppear {
            dnsDraft = state.dnsSettings
            testURLDraft = state.testURLString
            tunDraft = state.tunSettings
        }
        // 绕过设置在别处应用（如恢复默认）后，草稿同步跟上。
        // 开关是立即生效的，草稿要跟上，否则"有未应用的修改"会一直挂着。
        // 只在草稿未脏时跟随外部变化：脏着就同步会把用户没应用完的编辑冲掉。
        .onChange(of: state.tunSettings) { old, new in
            if tunDraft == old { tunDraft = new }
        }
        .fileExporter(
            isPresented: $showsBackupExporter,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "kongshan-backup"
        ) { result in
            switch result {
            case .success:
                backupNotice = "已导出"
            case let .failure(error):
                state.errorMessage = "导出备份失败：\(error.localizedDescription)"
            }
            backupDocument = nil
        }
        .fileExporter(
            isPresented: $showsDiagnosticExporter,
            document: diagnosticDocument,
            contentType: .plainText,
            defaultFilename: "kongshan-diagnostics"
        ) { result in
            if case let .failure(error) = result {
                state.errorMessage = "导出诊断失败：\(error.localizedDescription)"
            }
            diagnosticDocument = nil
        }
        .fileImporter(isPresented: $showsBackupImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    Task {
                        await state.importBackup(data)
                        if state.errorMessage == nil {
                            backupNotice = "已恢复"
                            dnsDraft = state.dnsSettings
                            testURLDraft = state.testURLString
                        }
                    }
                } catch {
                    state.errorMessage = "读取备份失败：\(error.localizedDescription)"
                }
            case let .failure(error):
                state.errorMessage = "选择备份失败：\(error.localizedDescription)"
            }
        }
    }

    private func prepareBackupExport() {
        isPreparingBackup = true
        backupNotice = nil
        Task {
            defer { isPreparingBackup = false }
            do {
                backupDocument = BackupDocument(data: try await state.exportBackup())
                showsBackupExporter = true
            } catch {
                state.errorMessage = "准备备份失败：\(error.localizedDescription)"
            }
        }
    }

    private func prepareDiagnosticExport() {
        isPreparingDiagnostics = true
        Task {
            defer { isPreparingDiagnostics = false }
            do {
                diagnosticDocument = TextExportDocument(text: try await state.exportDiagnostics())
                showsDiagnosticExporter = true
            } catch {
                state.errorMessage = "准备诊断失败：\(error.localizedDescription)"
            }
        }
    }

    /// 从打包进 App 的 Info.plist 读取版本，展示当前运行的是哪个构建。
    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// 拆成属性而不是在 body 里拼：Form 的分支多了之后，
    /// 带插值的多段字符串拼接会把类型推断压垮（编译报 unable to type-check in reasonable time）。
    private var tunFooterText: String {
        let dns = state.tunSettings.dnsServerAddress
        return "开关在仪表盘与菜单栏图标里。严格路由更彻底，但可能影响局域网、虚拟机或其他 VPN。"
            + "TUN 运行期间系统 DNS 会临时指向 \(dns) 以防解析绕过 TUN（macOS 特性），关闭或退出时自动还原。"
    }

    private var speedTestMethodBinding: Binding<SpeedTestMethod> {
        Binding(
            get: { state.speedTestMethod },
            set: { method in Task { await state.setSpeedTestMethod(method) } }
        )
    }


    private var activeModesText: String {
        let ordered: [ProxyMode] = [.systemProxy, .tun]
        let names = ordered.filter(state.activeModes.contains).map(\.displayName)
        return names.isEmpty ? "未开启" : names.joined(separator: " + ")
    }

    private var helperStatusText: String {
        switch state.helperInstallStatus {
        case .notInstalled: "未安装"
        case .installed: "已安装"
        case .needsReinstall: "需重装"
        }
    }

    /// TUN 是否正在接管。安装/卸载助手会 bootout helper，此时做会留下孤儿 root 内核。
    private var tunActive: Bool {
        state.activeModes.contains(.tun)
    }

    private var detectedLANServersText: String {
        let servers = state.lanResolverSnapshot.servers
        return servers.isEmpty ? "未探测到（接管系统 DNS 前读取）" : servers.joined(separator: "、")
    }

    private var detectedLANDomainsText: String {
        let domains = state.lanResolverSnapshot.searchDomains
        return domains.isEmpty ? "未探测到（可在下方手填）" : domains.joined(separator: "、")
    }

    private var lanDNSEnabledBinding: Binding<Bool> {
        Binding(
            get: { state.tunSettings.lanDNSEnabled },
            set: { enabled in
                var settings = state.tunSettings
                settings.lanDNSEnabled = enabled
                Task { await state.applyTunSettings(settings) }
            }
        )
    }

    private var menuBarIconStyleBinding: Binding<MenuBarIconStyle> {
        Binding(
            get: { state.menuBarIconStyle },
            set: { style in Task { await state.setMenuBarIconStyle(style) } }
        )
    }

    private var strictRouteBinding: Binding<Bool> {
        Binding(
            get: { state.tunSettings.strictRoute },
            set: { enabled in
                var settings = state.tunSettings
                settings.strictRoute = enabled
                Task { await state.applyTunSettings(settings) }
            }
        )
    }

    private var autoRestoreBinding: Binding<Bool> {
        Binding(
            get: { state.autoRestoreOnLaunch },
            set: { newValue in Task { await state.setAutoRestoreOnLaunch(newValue) } }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { state.loginItemStatus == .enabled },
            set: { enabled in
                Task { await state.setLaunchAtLoginEnabled(enabled) }
            }
        )
    }

    private var mirrorBinding: Binding<RuleSetMirror> {
        Binding(
            get: { state.ruleSetSettings.mirror },
            set: { mirror in
                var settings = state.ruleSetSettings
                settings.mirror = mirror
                Task { await state.setRuleSetSettings(settings) }
            }
        )
    }

    private var ruleSetAutoUpdateBinding: Binding<Bool> {
        Binding(
            get: { state.ruleSetSettings.autoUpdate },
            set: { enabled in
                var settings = state.ruleSetSettings
                settings.autoUpdate = enabled
                Task { await state.setRuleSetSettings(settings) }
            }
        )
    }

    private var lastRuleSetUpdateText: String {
        guard let date = state.ruleSetSettings.lastUpdatedAt else { return "从未更新" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var loginItemStatusTitle: String {
        switch state.loginItemStatus {
        case .notRegistered: "未启用"
        case .enabled: "已启用"
        case .requiresApproval: "等待系统批准"
        case .notRegisteredYet: "未注册（打开开关即可）"
        case .unsupported: "应用包不可用"
        }
    }
}
