import KongshanCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarPage? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(SidebarPage.allCases, selection: $selection) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .navigationTitle("kongshan")
        } detail: {
            switch selection ?? .dashboard {
            case .dashboard:
                DashboardView()
            case .nodes:
                NodesView()
            case .rules:
                RoutingView()
            case .logs:
                LogsView()
            case .settings:
                SettingsView()
            }
        }
    }
}

private enum SidebarPage: String, CaseIterable, Identifiable {
    case dashboard
    case nodes
    case rules
    case logs
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .nodes: "节点"
        case .rules: "规则"
        case .logs: "日志"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .rules: "list.bullet.rectangle.portrait"
        case .logs: "doc.text.magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

private struct NodesView: View {
    @Environment(AppState.self) private var state
    @State private var subscriptionURL = ""
    @State private var showingManualNode = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Clash 订阅 URL", text: $subscriptionURL)
                    .textFieldStyle(.roundedBorder)
                Button("导入") { importSubscription() }
                    .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    Task { await state.refreshSubscriptions() }
                } label: {
                    Label("刷新订阅", systemImage: "arrow.clockwise")
                }
                .disabled(state.subscriptions.isEmpty || state.isBusy)
                Button {
                    showingManualNode = true
                } label: {
                    Label("手动 Hysteria2", systemImage: "plus")
                }
                Button("测速全部") {
                    Task { await state.testAllDelays() }
                }
                .disabled(!state.isOn || state.nodes.isEmpty)
            }
            .padding()

            if let warning = state.warnings.last {
                HStack {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(warning).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 10)
            }

            Divider()

            List {
                ForEach(state.subscriptions) { source in
                    Section(source.name) {
                        ForEach(state.nodes(for: source)) { node in
                            NodeRow(node: node)
                        }
                    }
                }
                if !state.manualNodes.isEmpty {
                    Section("手动节点") {
                        ForEach(state.manualNodes) { node in
                            NodeRow(node: node)
                        }
                    }
                }
            }
            .overlay {
                if state.nodes.isEmpty {
                    ContentUnavailableView(
                        "还没有节点",
                        systemImage: "tray",
                        description: Text("导入订阅或添加手动节点。")
                    )
                }
            }
        }
        .navigationTitle("节点")
        .sheet(isPresented: $showingManualNode) {
            ManualNodeSheet()
                .environment(state)
        }
    }

    private func importSubscription() {
        let value = subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value) else {
            state.errorMessage = "订阅 URL 无效"
            return
        }
        Task {
            await state.importSubscription(url: url)
            if state.errorMessage == nil { subscriptionURL = "" }
        }
    }
}

private struct NodeRow: View {
    @Environment(AppState.self) private var state
    let node: ProxyNode

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(node.name).lineLimit(1)
                Text(node.protocolType.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
            }
            Spacer()
            delayLabel
                .frame(minWidth: 70, alignment: .trailing)
            Button("测速") { Task { await state.testDelay(node) } }
                .disabled(!state.isOn)
            Button {
                Task { await state.select(node) }
            } label: {
                Label(
                    state.selectedNodeID == node.id ? "已选择" : "选择",
                    systemImage: state.selectedNodeID == node.id ? "checkmark.circle.fill" : "circle"
                )
            }
            .buttonStyle(.borderless)
            .disabled(state.isBusy)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var delayLabel: some View {
        if let recorded = state.delays[node.id] {
            if let milliseconds = recorded {
                Text("\(milliseconds) ms")
                    .foregroundStyle(delayColor(milliseconds))
            } else {
                Text("超时").foregroundStyle(.red)
            }
        } else {
            Text("未测试").foregroundStyle(.secondary)
        }
    }

    private func delayColor(_ value: Int) -> Color {
        if value < 150 { return .green }
        if value < 350 { return .orange }
        return .red
    }
}

private struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var dnsDraft = DNSSettings.defaults
    @State private var subscriptionUpdateDraft = SubscriptionUpdateSettings.defaults

    var body: some View {
        Form {
            Section("代理模式") {
                Picker("首选接管方式", selection: modeBinding) {
                    Text("系统代理").tag(ProxyMode.systemProxy)
                    Text("TUN").tag(ProxyMode.tun)
                }
                .pickerStyle(.segmented)
                .disabled(state.isBusy || !state.isReady)

                LabeledContent("当前接管", value: state.activeMode.map(modeTitle) ?? "未开启")
                Text("TUN 模式的启动和停止需要管理员授权。")
                    .foregroundStyle(.secondary)

                Toggle("严格路由（strict_route）", isOn: strictRouteBinding)
                    .disabled(state.isBusy || !state.isReady)
                Text("启用更严格的路由处理，可能影响局域网或虚拟化软件；macOS 上的 DNS 防泄漏仍需 M4 DNS 设置验证")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("测速") {
                TextField("测试 URL", text: Binding(
                    get: { state.testURLString },
                    set: { state.testURLString = $0 }
                ))
                HStack {
                    Text("超时")
                    Spacer()
                    Text("5 秒").foregroundStyle(.secondary)
                }
                Button("保存设置") { Task { await state.saveSettings() } }
            }

            Section("DNS 高级设置") {
                TextField("国内 DoH", text: $dnsDraft.domesticDoH)
                TextField("远程 DoH", text: $dnsDraft.remoteDoH)
                Text("geosite-cn 使用国内 DoH 直连解析，其余域名使用经当前代理的远程 DoH。兼容性优先，默认不启用 fake-ip。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("系统代理模式只管理进入本地 mixed 代理的域名解析，不等同于接管 macOS 全局 DNS。")
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

            Section("订阅自动更新") {
                Toggle("启用自动更新", isOn: $subscriptionUpdateDraft.enabled)
                Stepper(
                    "更新间隔：\(subscriptionUpdateDraft.intervalHours) 小时",
                    value: $subscriptionUpdateDraft.intervalHours,
                    in: 1...168
                )
                .disabled(!subscriptionUpdateDraft.enabled)
                LabeledContent(
                    "下次更新",
                    value: state.nextSubscriptionUpdateAt?.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ) ?? "未安排"
                )
                Text("应用在后台按最近到期的订阅安排一次更新；更新结束后重新计算时间，不会持续轮询。失败时保留原节点和缓存，并尝试发送本地通知。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("放弃修改") {
                        subscriptionUpdateDraft = state.subscriptionUpdateSettings
                    }
                    .disabled(subscriptionUpdateDraft == state.subscriptionUpdateSettings)
                    Spacer()
                    Button("应用自动更新设置") {
                        Task {
                            await state.setSubscriptionUpdateSettings(subscriptionUpdateDraft)
                            subscriptionUpdateDraft = state.subscriptionUpdateSettings
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        state.isBusy
                            || !state.isReady
                            || subscriptionUpdateDraft == state.subscriptionUpdateSettings
                    )
                }
            }

            Section("当前能力") {
                LabeledContent("代理模式", value: "系统代理 + TUN")
                LabeledContent("分流", value: "自定义规则 + 中国直连")
                Text("Dashboard 流量曲线、实时日志和订阅自动更新已可用。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .onAppear {
            dnsDraft = state.dnsSettings
            subscriptionUpdateDraft = state.subscriptionUpdateSettings
        }
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { state.preferredMode },
            set: { mode in Task { await state.switchMode(to: mode) } }
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

    private func modeTitle(_ mode: ProxyMode) -> String {
        mode == .tun ? "TUN" : "系统代理"
    }
}

private struct ManualNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var state
    @State private var name = ""
    @State private var server = ""
    @State private var port = "443"
    @State private var password = ""
    @State private var sni = ""
    @State private var skipCertificateVerification = false
    @State private var obfsPassword = ""
    @State private var uploadMbps = ""
    @State private var downloadMbps = ""
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名称", text: $name)
                TextField("服务器", text: $server)
                TextField("端口", text: $port)
                SecureField("密码", text: $password)
                TextField("SNI（可选）", text: $sni)
                Toggle("跳过证书验证", isOn: $skipCertificateVerification)
                TextField("Obfs 密码（可选）", text: $obfsPassword)
                TextField("上行 Mbps（可选）", text: $uploadMbps)
                TextField("下行 Mbps（可选）", text: $downloadMbps)
                if let localError {
                    Text(localError).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { addNode() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 440, height: 510)
    }

    private func addNode() {
        guard let portValue = Int(port),
              let uploadValue = optionalInt(uploadMbps),
              let downloadValue = optionalInt(downloadMbps) else {
            localError = "端口和带宽必须是整数"
            return
        }
        let form = ManualHysteria2(
            name: name,
            server: server,
            port: portValue,
            password: password,
            sni: sni,
            skipCertificateVerification: skipCertificateVerification,
            obfsPassword: obfsPassword.isEmpty ? nil : obfsPassword,
            uploadMbps: uploadValue,
            downloadMbps: downloadValue
        )
        do {
            _ = try form.makeNode()
        } catch {
            localError = error.localizedDescription
            return
        }
        Task {
            await state.addManual(form)
            if state.errorMessage == nil { dismiss() }
        }
    }

    private func optionalInt(_ value: String) -> Int?? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? .some(nil) : Int(trimmed).map(Optional.some)
    }
}
