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
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .nodes: "节点"
        case .rules: "规则"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.67percent"
        case .nodes: "point.3.connected.trianglepath.dotted"
        case .rules: "list.bullet.rectangle.portrait"
        case .settings: "gearshape"
        }
    }
}

private struct DashboardView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(systemName: state.menuBarSymbol)
                    .font(.system(size: 42))
                    .foregroundStyle(state.isOn ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.statusText)
                        .font(.title2.weight(.semibold))
                    Text(state.selectedNode.map { "当前节点：\($0.name)" } ?? "尚未选择节点")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(state.activeMode != nil ? "关闭代理" : "开启\(modeTitle(state.preferredMode))") {
                    Task {
                        if state.activeMode != nil {
                            await state.stop()
                        } else {
                            await state.startPreferredProxy()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.isBusy || !state.isReady)
            }

            GroupBox("代理模式") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("首选接管方式", selection: modeBinding) {
                        Text("系统代理").tag(ProxyMode.systemProxy)
                        Text("TUN").tag(ProxyMode.tun)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(state.isBusy || !state.isReady)

                    Text("TUN 模式的启动和停止需要管理员授权。在线切换会先完整关闭当前模式。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("运行信息") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        Text("当前接管").foregroundStyle(.secondary)
                        Text(state.activeMode.map(modeTitle) ?? "未接管（首选\(modeTitle(state.preferredMode))）")
                    }
                    GridRow { Text("节点数").foregroundStyle(.secondary); Text("\(state.nodes.count)") }
                    GridRow {
                        Text("Mixed 端口").foregroundStyle(.secondary)
                        Text(
                            state.activeMode == .tun
                                ? "TUN 模式不使用"
                                : (state.mixedPort.map(String.init) ?? "未启动")
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            if let error = state.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("忽略") { state.dismissError() }
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if state.nodes.isEmpty {
                ContentUnavailableView(
                    "还没有节点",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("请在“节点”页导入 Clash 订阅或添加手动 Hysteria2。")
                )
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Dashboard")
    }

    private var modeBinding: Binding<ProxyMode> {
        Binding(
            get: { state.preferredMode },
            set: { mode in Task { await state.switchMode(to: mode) } }
        )
    }

    private func modeTitle(_ mode: ProxyMode) -> String {
        mode == .tun ? "TUN" : "系统代理"
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

            Section("当前能力") {
                LabeledContent("代理模式", value: "系统代理 + TUN")
                LabeledContent("分流", value: "自定义规则 + 中国直连")
                Text("Dashboard 流量曲线和自动订阅更新将在 M4 提供。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
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
