import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 设置

/// 2026-09-17 信息架构重构：5 分区 → 4 分区。
/// 2026-11-06 改为全 App 统一「小窗」风格（TilePage + TileMasonry + TileCard）。
/// 2026-11-09 原型重做：前六张小窗按原型固定两列（左：开机自启 / 内网 DNS 分流 / 外观；
/// 右：接管 / DNS 高级设置 / 内网域名后缀），其余分区用瀑布流续排。
/// `initialTab` 不再切换内容，只在打开时滚动到该分组的第一个小窗（`RenderSnapshotTests` 仍按 tab 构造）。
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

/// 非 private：`RenderSnapshotTests` 要单独渲染这一页。一页瀑布流（TileMasonry），
/// 宽窗口自动多列、窄窗口单列；`initialTab` 只决定打开时滚动到哪个分组。
struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var dnsDraft = DNSSettings.defaults
    @State private var tunDraft = TunSettings.defaults
    /// 打开时滚动到的分组锚点。分段切换已删（小窗合并成一页），tab 只剩这一个用途。
    private let tab: SettingsTab

    /// `initialTab` 为离屏快照而设：不再切换内容，只决定打开时滚到哪一组的第一个小窗。
    init(initialTab: SettingsTab = .general) {
        tab = initialTab
    }

    @State private var backupDocument: BackupDocument?
    @State private var showsBackupExporter = false
    @State private var showsBackupImporter = false
    @State private var isPreparingBackup = false
    @State private var backupNotice: String?
    /// 导出前问口令（可留空）；导入加密备份时问口令。备份含节点凭据（2026-10-25 审计 S6）。
    @State private var showsExportPasswordPrompt = false
    @State private var exportPassword = ""
    @State private var exportPasswordConfirm = ""
    @State private var pendingEncryptedBackup: Data?
    @State private var importPassword = ""

    /// 内网域名后缀添加草稿
    @State private var lanDomainInput = ""
    @State private var lanDomainInputError: String?

    var body: some View {
        // ScrollViewReader 包在 TilePage 外：锚点滚动要的是它里面那个 ScrollView。
        ScrollViewReader { proxy in
            TilePage {
                TileMasonry(minColumnWidth: 300, maxColumns: 2) {
                    launchAtLoginCard
                    scrollAnchor(.takeover) { takeoverCard }
                    scrollAnchor(.network) { dnsAdvancedCard }
                    lanDNSCard
                    lanDomainSuffixesCard
                    appearanceCard
                    scrollAnchor(.maintenance) { backupCard }
                    dataAndLogsCard
                    cleanupCard
                    aboutCard
                }
            }
            .onAppear {
                dnsDraft = state.dnsSettings
                tunDraft = state.tunSettings
                // .general 的第一张小窗本来就在页首，再 scrollTo 只会把它顶到滚动区上沿、
                // 吃掉页面边距；只有定位其他分组时才滚。
                guard tab != .general else { return }
                // 等布局首帧量完再滚，否则锚点位置还没算出来，scrollTo 会落空。
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    proxy.scrollTo(tab, anchor: .top)
                }
            }
        }
        .toggleStyle(CardRowToggleStyle())
        .labeledContentStyle(CardRowLabeledContentStyle())
        .pageTopBar {}
        // 绕过设置在别处应用（如恢复默认）后，草稿同步跟上。
        // 开关是立即生效的，草稿要跟上，否则"有未应用的修改"会一直挂着。
        // 只在草稿未脏时跟随外部变化：脏着就同步会把用户没应用完的编辑冲掉。
        .onChange(of: state.tunSettings) { old, new in
            if tunDraft == old {
                tunDraft = new
            } else {
                // 草稿脏着时只吸收立即生效的两个开关：「应用」提交的是整份草稿，
                // 不吸收的话会把刚打开的严格路由 / 内网 DNS 悄悄关回去。
                if old.strictRoute != new.strictRoute { tunDraft.strictRoute = new.strictRoute }
                if old.lanDNSEnabled != new.lanDNSEnabled { tunDraft.lanDNSEnabled = new.lanDNSEnabled }
            }
        }
        .onChange(of: lanDomainInput) { _, _ in
            lanDomainInputError = nil
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
        .fileImporter(isPresented: $showsBackupImporter, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let data = try Data(contentsOf: url)
                    if BackupEncryption.isEncrypted(data) {
                        pendingEncryptedBackup = data
                    } else {
                        restore(data, password: nil)
                    }
                } catch {
                    state.errorMessage = "读取备份失败：\(error.localizedDescription)"
                }
            case let .failure(error):
                state.errorMessage = "选择备份失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 小窗（按 body 里的使用频率顺序排布）

    /// 滚动锚点包装：`scrollTo(anchor: .top)` 会把小窗顶到滚动区上沿、吃掉 20pt 页面边距。
    /// 在小窗上方垫一层 `pagePadding` 高的透明锚点、再用负 padding 收回高度：
    /// 滚动停下时小窗上方仍留一页边距的画布，卡片间距不受影响。
    /// 锚点层向上溢出 20pt（间距只有 16pt，会盖住上张卡片底边 4pt），
    /// 所以关掉命中测试与无障碍，纯当定位标记。
    @ViewBuilder
    private func scrollAnchor(_ tab: SettingsTab, @ViewBuilder card: () -> some View) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: Theme.pagePadding)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .id(tab)
            card()
        }
        .padding(.top, -Theme.pagePadding)
    }

    /// 外观小窗：菜单栏图标下拉选择。
    private var appearanceCard: some View {
        TileCard("外观", symbol: "paintpalette", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("菜单栏图标") {
                    PillMenuPicker(
                        options: MenuBarIconStyle.allCases,
                        selection: menuBarIconStyleBinding,
                        title: { $0.displayName }
                    )
                }

                Text(verbatim: "\(state.menuBarIconStyle.summary)。关闭为线稿，开启填实，TUN 带点。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("\(state.menuBarIconStyle.summary)。菜单栏会把图标染成单色，所以状态靠形状区分：关闭时是线稿、开启后填实、TUN 额外加一个点。")
            }
        }
    }

    /// 开机自启小窗：登录项开关与自动恢复状态。
    private var launchAtLoginCard: some View {
        TileCard("开机自启", symbol: "power", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("登录时启动 kongshan", isOn: launchAtLoginBinding)
                    .disabled(
                        !state.isReady
                            || state.loginItemStatus == .requiresApproval
                            || state.loginItemStatus == .unsupported
                    )

                LabeledContent("登录项状态", value: loginItemStatusTitle)

                Toggle("登录后自动恢复上次的接管", isOn: autoRestoreBinding)
                    .disabled(!state.isReady || state.loginItemStatus != .enabled)

                HStack(alignment: .center, spacing: 12) {
                    Text("登录后等待网络就绪，自动恢复上次退出时的接管。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("仅在开机自启场景生效：登录后等待网络就绪，再恢复上次正常退出时的系统代理与 TUN。恢复 TUN 需要可用的免密码助手；助手不可用时跳过整组接管并通知原因，不会在登录时突然弹出密码框。")
                    Spacer(minLength: 8)
                    Button("刷新状态") {
                        Task { await state.refreshLoginItemStatus() }
                    }
                    .controlSize(.small)
                    .disabled(!state.isReady)
                }

                if state.loginItemStatus == .requiresApproval {
                    HStack {
                        Text("登录项已登记，需在系统设置中批准。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .help("登录项已登记，但需要你在系统设置中批准。应用不会重复发起注册。")
                        Spacer()
                        Button("打开系统设置") {
                            Task { await state.openLoginItemSystemSettings() }
                        }
                        .controlSize(.small)
                    }
                } else if state.loginItemStatus == .unsupported {
                    Text("当前环境非可注册应用包；请从打包后的 kongshan.app 使用。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("当前运行环境不是可注册的应用包；请从打包后的 kongshan.app 使用此功能。")
                }
            }
        }
    }

    /// 关于小窗：版本、内核版本、检查更新紧凑两行。
    private var aboutCard: some View {
        TileCard("关于", symbol: "info.circle", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("应用版本") {
                    HStack(spacing: 8) {
                        Text(Self.appVersion)
                            .font(.system(size: 12).monospacedDigit())
                        Button("查看最新版本") {
                            if let url = URL(string: "https://github.com/kongshan-0924/kongshan-proxy/releases/latest") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("内核") {
                    HStack(spacing: 8) {
                        // coreVersion 是内核 /version 的原样返回，已经带名字（`sing-box 1.13.14`）。
                        Text(state.coreVersion)
                            .font(.system(size: 12).monospacedDigit())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(state.coreVersion)
                        Button(state.isCheckingKernelUpdate ? "检查中…" : "检查内核更新") {
                            Task { await state.updateKernel() }
                        }
                        .controlSize(.small)
                        .disabled(state.isCheckingKernelUpdate)
                    }
                }
            }
        }
    }

    // MARK: - 接管小窗

    /// 接管小窗：TUN 严格路由与免密码助手合成一张——助手只为 TUN 服务，
    /// 分成两张卡各自只有两三行，竖向空间全浪费在标题与留白上。
    private var takeoverCard: some View {
        TileCard("接管", symbol: "shield.lefthalf.filled", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("严格路由（strict_route）", isOn: strictRouteBinding)
                    .disabled(state.isBusy || !state.isReady)

                Text("严格路由更彻底，但可能影响局域网、虚拟机或其他 VPN。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(tunFooterText)

                Theme.separator.frame(height: 0.5)

                LabeledContent("免密码助手", value: helperStatusText)

                HStack(alignment: .center, spacing: 12) {
                    Text("让 TUN 启停无需输入密码，开机自启。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("免密码助手让 TUN 启停无需每次输入密码：安装需一次管理员授权，之后开机自动运行。未装时 TUN 仍可用（每次弹密码）。")
                    Spacer(minLength: 8)
                    if state.isHelperOperationInProgress {
                        ProgressView().controlSize(.small)
                    }
                    switch state.helperInstallStatus {
                    case .notInstalled:
                        Button("安装") {
                            Task { await state.installHelper() }
                        }
                        .buttonStyle(.pillProminent)
                        .controlSize(.small)
                        .disabled(state.isHelperOperationInProgress || tunActive)
                    case .installed:
                        Button("卸载") {
                            Task { await state.uninstallHelper() }
                        }
                        .controlSize(.small)
                        .disabled(state.isHelperOperationInProgress || tunActive)
                    case .needsReinstall:
                        Button("重新安装") {
                            Task { await state.installHelper() }
                        }
                        .buttonStyle(.pillProminent)
                        .controlSize(.small)
                        .disabled(state.isHelperOperationInProgress || tunActive)
                    }
                }

                if state.helperInstallStatus == .needsReinstall {
                    Text("助手需要更新（内核更新或应用移动过位置），点「重新安装」授权。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("助手需要更新 —— 通常是内置内核或助手换了新版，或 App 被移动过位置。点「重新安装」授权一次即可，之后继续零弹窗。")
                }

                if tunActive {
                    Text("TUN 正在运行，安装/卸载助手已暂时禁用；请先关闭 TUN。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning.text)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("TUN 正在运行，安装/卸载助手已暂时禁用——请先关闭 TUN，避免残留无法清理的 root 内核。")
                }

                if let error = state.helperOperationError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - 网络小窗

    /// DNS 高级设置小窗：国内 DNS、远程 DoH、引导解析器。
    private var dnsAdvancedCard: some View {
        TileCard("DNS 高级设置", symbol: "antenna.radiowaves.left.and.right", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("国内 DNS") {
                    TextField("国内 DNS", text: $dnsDraft.domesticDNS, prompt: Theme.inputPrompt("IP 或 https://…"))
                        .labelsHidden()
                        .font(.system(size: 12))
                        .inputField()
                        .frame(maxWidth: 240)
                }

                LabeledContent("远程 DoH") {
                    TextField("远程 DoH", text: $dnsDraft.remoteDoH, prompt: Theme.inputPrompt("https://…"))
                        .labelsHidden()
                        .font(.system(size: 12))
                        .inputField()
                        .frame(maxWidth: 240)
                }

                LabeledContent("引导解析器") {
                    TextField("引导解析器", text: $dnsDraft.bootstrapResolver, prompt: Theme.inputPrompt("可选，如 114.114.114.114"))
                        .labelsHidden()
                        .font(.system(size: 12))
                        .inputField()
                        .frame(maxWidth: 240)
                }

                Text("国内域名直连问国内 DNS，其余走远程 DoH；TUN 默认使用 Fake-IP。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("国内域名直连问国内 DNS：填 IP 走 UDP（默认，睡眠唤醒、长时间闲置后都不卡），填 https:// 地址走 DoH；其余域名走当前代理的远程 DoH。TUN 默认使用 Fake-IP；系统代理只处理进入本地 mixed 代理的流量，不接管 macOS 全局 DNS。引导解析器负责解析出站节点自身的域名，必须是无连接的 UDP。留空时跟随国内 DNS 的地址；填入独立 IP（如 114.114.114.114）可与国内 DNS 解耦，避免一台上游抖动同时影响节点域名与国内域名解析。")

                HStack(spacing: 8) {
                    Button("恢复默认") { dnsDraft = .defaults }
                        .controlSize(.small)
                    Button("放弃修改") { dnsDraft = state.dnsSettings }
                        .controlSize(.small)
                        .disabled(dnsDraft == state.dnsSettings)
                    Spacer()
                    Button("应用 DNS") {
                        Task {
                            await state.applyDNSSettings(dnsDraft)
                            // 只在生效后换成归一化的值；失败时留着输入，改一处就能重试。
                            if state.dnsSettings == (try? dnsDraft.validated()) { dnsDraft = state.dnsSettings }
                        }
                    }
                    .buttonStyle(.pillProminent)
                    .controlSize(.small)
                    .disabled(state.isBusy || !state.isReady || dnsDraft == state.dnsSettings)
                }
            }
        }
    }

    /// 内网 DNS 分流表单小窗：总开关收进标题行右侧（原型），卡内是探测状态与服务器输入。
    private var lanDNSCard: some View {
        TileCard(
            "内网 DNS 分流",
            symbol: "arrow.triangle.branch",
            height: nil,
            trailing: {
                Toggle("把内网域名交给内网 DNS 解析", isOn: lanDNSEnabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(state.isBusy || !state.isReady)
                    .accessibilityLabel("内网 DNS 分流")
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("自动探测到的 DNS") {
                    Text(detectedLANServersText)
                        .font(.system(size: 12))
                }

                LabeledContent("自动探测到的域名") {
                    Text(detectedLANDomainsText)
                        .font(.system(size: 12))
                }

                LabeledContent("内网 DNS 服务器") {
                    TextField("内网 DNS 服务器", text: $tunDraft.lanDNSServer, prompt: Theme.inputPrompt("留空＝用自动探测"))
                        .labelsHidden()
                        .font(.system(size: 12))
                        .inputField()
                        .frame(maxWidth: 200)
                }
                .disabled(!state.tunSettings.lanDNSEnabled || state.isBusy || !state.isReady)

                HStack(alignment: .center, spacing: 12) {
                    if tunDraft != state.tunSettings {
                        StatusBadge(text: "未应用", style: Theme.warning)
                    }
                    Text("关闭后内网域名会落到 Fake-IP，改动会重载内核。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("关掉它，内网域名会落到 Fake-IP 拿到一个 240.x 假地址，然后整段被路由进代理出口——表现就是内网设备一直加载。探测在接管系统 DNS 之前进行；网络不下发搜索域时，用内网域名后缀小窗手填。")
                    Spacer(minLength: 8)
                    Button("应用") {
                        Task { await state.applyTunSettings(tunDraft) }
                    }
                    .controlSize(.small)
                    .disabled(state.isBusy || tunDraft == state.tunSettings)
                }
            }
        }
    }

    /// 内网域名后缀小窗：贴合内容列表。
    private var lanDomainSuffixesCard: some View {
        TileCard(
            "内网域名后缀",
            symbol: "globe",
            detail: tunDraft.lanDomainSuffixes.isEmpty ? nil : "\(tunDraft.lanDomainSuffixes.count) 条",
            height: nil,
            trailing: {
                if tunDraft != state.tunSettings {
                    Button("应用") {
                        Task { await state.applyTunSettings(tunDraft) }
                    }
                    .disabled(state.isBusy)
                    .help("改动会重载内核并断开当前连接。")
                }
            },
            fixedHeader: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("例如 corp.example.com", text: $lanDomainInput, prompt: Theme.inputPrompt("例如 corp.example.com 或 *.corp.example.com"))
                            .labelsHidden()
                            .font(.system(size: 12))
                            .inputField(isInvalid: lanDomainInputError != nil)
                            .onSubmit(addLanDomainSuffix)
                        Button("添加", action: addLanDomainSuffix)
                            .disabled(lanDomainInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let lanDomainInputError {
                        Label {
                            Text(lanDomainInputError).foregroundStyle(Theme.danger.text)
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundStyle(Theme.danger.icon)
                        }
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            },
            content: {
                if tunDraft.lanDomainSuffixes.isEmpty {
                    TileEmptyNote(symbol: "globe", text: "暂无内网域名后缀，在上方填写后添加")
                } else {
                    ForEach(tunDraft.lanDomainSuffixes, id: \.self) { suffix in
                        TileRow(
                            symbol: "globe",
                            suffix,
                            showsDivider: suffix != tunDraft.lanDomainSuffixes.last
                        ) {
                            Button {
                                tunDraft.lanDomainSuffixes.removeAll { $0 == suffix }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.danger.icon)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("删除 \(suffix)")
                            .help("删除 \(suffix)")
                        }
                    }
                }
            }
        )
    }

    // MARK: - 维护小窗

    /// 备份与恢复小窗：导出/导入配置快照与凭据。
    private var backupCard: some View {
        TileCard("备份与恢复", symbol: "externaldrive", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                Button {
                    exportPassword = ""
                    exportPasswordConfirm = ""
                    showsExportPasswordPrompt = true
                } label: {
                    Label("导出配置与设置", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingBackup)
                .alert("给备份设个口令？", isPresented: $showsExportPasswordPrompt) {
                    SecureField("口令", text: $exportPassword)
                    SecureField("再输一次", text: $exportPasswordConfirm)
                    Button("加密导出") {
                        guard !exportPassword.isEmpty, exportPassword == exportPasswordConfirm else {
                            state.errorMessage = exportPassword.isEmpty ? "口令为空；不想加密请选「不加密导出」" : "两次输入的口令不一样"
                            return
                        }
                        prepareBackupExport(password: exportPassword)
                    }
                    Button("不加密导出") { prepareBackupExport(password: nil) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("备份里有订阅链接和节点凭据。设了口令，导入时要输同一个口令；口令忘了备份就打不开。")
                }

                Button {
                    showsBackupImporter = true
                } label: {
                    Label("导入备份", systemImage: "square.and.arrow.down")
                }
                .disabled(state.isOn || state.isBusy)
                .alert("输入备份口令", isPresented: Binding(
                    get: { pendingEncryptedBackup != nil },
                    set: { if !$0 { pendingEncryptedBackup = nil } }
                )) {
                    SecureField("口令", text: $importPassword)
                    Button("导入") {
                        guard let data = pendingEncryptedBackup else { return }
                        let password = importPassword
                        pendingEncryptedBackup = nil
                        importPassword = ""
                        restore(data, password: password)
                    }
                    Button("取消", role: .cancel) { importPassword = "" }
                } message: {
                    Text("这份备份导出时设了口令。")
                }

                if isPreparingBackup { ProgressView().controlSize(.small) }
                Spacer()
                if let backupNotice {
                    StatusBadge(text: backupNotice, style: Theme.success)
                }
                }

                Text("备份包含订阅、节点凭据与设置，导入前需先停止代理。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("备份包含订阅链接、订阅配置快照、节点凭据和全部设置，可能含敏感信息，导出时可设口令加密；不包含日志、运行时密钥或恢复文件。导入前需先停止代理。")
            }
        }
    }

    /// 数据与日志小窗：诊断与目录跳转。
    private var dataAndLogsCard: some View {
        TileCard("数据与日志", symbol: "folder", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("故障诊断") {
                    Button("打开诊断") { state.requestPage(.diagnostics) }
                        .controlSize(.small)
                }

                LabeledContent("数据目录") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([state.supportDirectory])
                    }
                    .controlSize(.small)
                }

                LabeledContent("日志目录") {
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            state.supportDirectory.appending(path: "logs", directoryHint: .isDirectory)
                        ])
                    }
                    .controlSize(.small)
                }

                Text(state.supportDirectory.path)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.supportDirectory.path)

                Text("完整版含内核日志与节点地址，公开分享请用公开分享版。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("两版都不含订阅原文、节点凭据或运行时密钥。完整版保留内核日志（访问过的网站与地址）和节点服务器地址，只发给信任的人；要贴到公开场合请用可公开分享版。")
            }
        }
    }

    /// 清理小窗：清理缓存。
    private var cleanupCard: some View {
        TileCard("清理", symbol: "trash", height: nil) {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("清理缓存") {
                    // 缓存为 0 时右侧不摆占位符「—」：空着，由下方按钮的禁用态表达无可清理。
                    if state.cacheSizeBytes > 0 {
                        Text(AppState.formatBytes(state.cacheSizeBytes))
                            .font(.system(size: 12).monospacedDigit())
                    }
                }

                Text("删除日志与规则集缓存，两者都会重新生成。需先停止内核。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("删除内核日志与规则集缓存，两者都会自动重新生成。设置、订阅缓存和节点不受影响。需先停止内核。")

                HStack {
                    Spacer()
                    Button("执行清理") {
                        Task { await state.clearRegenerableCaches() }
                    }
                    .controlSize(.small)
                    .disabled(state.isOn || state.isBusy || state.cacheSizeBytes == 0)
                }
            }
        }
        .task { await state.refreshCacheSize() }
    }

    // MARK: - 辅助操作

    private func addLanDomainSuffix() {
        let entries = lanDomainInput
            .split { $0 == "," || $0 == "，" || $0.isWhitespace }
            .map(String.init)
        guard !entries.isEmpty else { return }
        var accepted: [String] = []
        for entry in entries {
            guard let value = BypassListSection.normalized(entry, kind: .domain) else {
                lanDomainInputError = "「\(entry)」不是有效的域名，例如 corp.example.com 或 *.corp.example.com"
                return
            }
            if !tunDraft.lanDomainSuffixes.contains(value), !accepted.contains(value) {
                accepted.append(value)
            }
        }
        tunDraft.lanDomainSuffixes.append(contentsOf: accepted)
        lanDomainInput = ""
        lanDomainInputError = nil
    }

    private func restore(_ data: Data, password: String?) {
        Task {
            await state.importBackup(data, password: password)
            if state.errorMessage == nil {
                backupNotice = "已恢复"
                dnsDraft = state.dnsSettings
            }
        }
    }

    private func prepareBackupExport(password: String?) {
        isPreparingBackup = true
        backupNotice = nil
        Task {
            defer { isPreparingBackup = false }
            do {
                backupDocument = BackupDocument(data: try await state.exportBackup(password: password))
                showsBackupExporter = true
            } catch {
                state.errorMessage = "准备备份失败：\(error.localizedDescription)"
            }
        }
    }

    /// 从打包进 App 的 Info.plist 读取版本，展示当前运行的是哪个构建。
    static var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    /// 拆成属性而不是在 body 里拼：分支多了之后，
    /// 带插值的多段字符串拼接会把类型推断压垮（编译报 unable to type-check in reasonable time）。
    private var tunFooterText: String {
        let dns = state.tunSettings.dnsServerAddress
        return "开关在仪表盘与菜单栏图标里。严格路由更彻底，但可能影响局域网、虚拟机或其他 VPN。"
            + "TUN 运行期间系统 DNS 会临时指向 \(dns) 以防解析绕过 TUN（macOS 特性），关闭或退出时自动还原。"
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
