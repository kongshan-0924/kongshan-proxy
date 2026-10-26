import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口的 SwiftUI 内容。窗口关闭时卸下、打开时重建。
@MainActor
final class MainWindowContentHost {
    let hostingView: NSHostingView<AnyView>
    private let state: AppState
    private(set) var isAttached = false

    init(state: AppState) {
        self.state = state
        hostingView = NSHostingView(rootView: AnyView(EmptyView()))
        attachIfNeeded()
    }

    func attachIfNeeded() {
        guard !isAttached else { return }
        hostingView.rootView = AnyView(MainWindowView(initialPage: state.lastMainWindowPage).environment(state))
        isAttached = true
    }

    func detach() {
        guard isAttached else { return }
        hostingView.rootView = AnyView(EmptyView())
        isAttached = false
    }
}

struct MainWindowView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarPage?
    @State private var sidebarCollapsed = false

    init(initialPage: SidebarPage = .dashboard) {
        _selection = State(initialValue: initialPage)
    }

    private var activePage: SidebarPage {
        selection ?? .dashboard
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                // 侧栏 132pt：窗口默认 1008 宽的约 1/8，与内容区 7:1，符合紧凑单窗范式。
                customSidebar
                    .frame(width: 132)
            }

            detailCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvasBackground)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(sidebarCollapsed ? "显示侧边栏" : "隐藏侧边栏")
                .accessibilityLabel(sidebarCollapsed ? "显示侧边栏" : "隐藏侧边栏")
            }
            if activePage == .dashboard {
                ToolbarItem(placement: .automatic) {
                    DashboardToolbarMenu()
                }
            }
            ToolbarItem(placement: .automatic) {
                NativeNoticeToolbarItem(selection: $selection)
            }
        }
        // 顶栏不画自己的底衬：与下方冷云灰画布融为一体，去掉横贯窗口的分割带。
        .toolbarBackground(.hidden, for: .windowToolbar)
        .onAppear { state.noteVisiblePage(activePage.title) }
        .onDisappear { state.noteVisiblePage(nil) }
        .onChange(of: selection) { _, page in
            let current = page ?? .dashboard
            state.noteVisiblePage(current.title)
            state.lastMainWindowPage = current
        }
        .onChange(of: state.requestedPage, initial: true) { _, page in
            guard let page else { return }
            selection = page
            state.requestedPage = nil
        }
        .background {
            HStack(spacing: 0) {
                ForEach(Array(SidebarPage.allCases.enumerated()), id: \.element) { index, page in
                    if let key = SidebarPage.shortcutKey(at: index) {
                        Button(page.title) { selection = page }
                            .keyboardShortcut(key, modifiers: .command)
                    }
                }
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .navigationTitle("kongshan")
    }

    // MARK: - 定制侧边栏（宽 132pt，冷银灰底 + 纯白圆角浮起选区 + 细线分段）

    private var customSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    sidebarButton(.dashboard)

                    sidebarDivider

                    sidebarButton(.nodes)
                    sidebarButton(.policyGroups)
                    sidebarButton(.routing)

                    sidebarDivider

                    sidebarButton(.connections)
                    sidebarButton(.records)
                    sidebarButton(.diagnostics)

                    sidebarDivider

                    sidebarButton(.settings)
                }
                .padding(.horizontal, 9)
                .padding(.top, 10)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .background(Theme.sidebarFill.ignoresSafeArea(edges: .top))
        // 自绘侧栏没有系统 List 的方向键切换：点过侧栏后 ↑↓ 按侧栏顺序切页。
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let pages = SidebarPage.allCases
            guard let index = pages.firstIndex(of: activePage) else { return }
            switch direction {
            case .up where index > pages.startIndex:
                selection = pages[pages.index(before: index)]
            case .down where index < pages.index(before: pages.endIndex):
                selection = pages[pages.index(after: index)]
            default:
                break
            }
        }
    }

    private var sidebarDivider: some View {
        Divider()
            .opacity(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }

    private func sidebarButton(_ page: SidebarPage) -> some View {
        let isSelected = activePage == page
        return Button {
            selection = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 18, alignment: .center)

                Text(page.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if page == .records {
                    SidebarNoticeBadge()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Theme.cardStroke, lineWidth: 1)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// 侧栏底部状态条：拆成独立视图，状态变化只刷新它自己，不牵动整个主窗口重算。
    private var sidebarFooter: some View {
        SidebarStatusFooter { selection = .policyGroups }
    }

    // MARK: - 右侧主画布

    private var detailCanvas: some View {
        Group {
            switch activePage {
            case .dashboard:
                DashboardView()
            case .nodes:
                NodesView()
            case .policyGroups:
                PolicyGroupsView()
            case .routing:
                RoutingView()
            case .connections:
                ConnectionsPageView()
            case .records:
                RecordsPageView()
            case .diagnostics:
                DiagnosticsView()
            case .settings:
                SettingsView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvasBackground)
    }
}

/// 仪表盘顶栏的检测入口：探测出口与网络自检收进一个菜单，顶栏不再散落两枚孤立图标。
private struct DashboardToolbarMenu: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Menu {
            Button {
                Task { await state.refreshExitDiagnostics() }
            } label: {
                Label("立即探测出口", systemImage: "globe.asia.australia")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.isRefreshingExitDiagnostics)

            Divider()

            Button {
                state.requestPage(.diagnostics)
            } label: {
                Label("网络自检与诊断", systemImage: "stethoscope")
            }
        } label: {
            Image(systemName: "waveform.path.ecg")
        }
        .menuIndicator(.hidden)
        .help("网络检测：探测出口（⌘R）、网络自检")
    }
}

/// 原生 macOS 工具栏通知组件。
private struct NativeNoticeToolbarItem: View {
    @Environment(AppState.self) private var state
    @Binding var selection: SidebarPage?
    @State private var showingPopover = false

    private var hasNotice: Bool {
        state.errorMessage != nil || !state.warnings.isEmpty
    }

    private var noticeColor: Color {
        if state.errorMessage != nil { return .red }
        if !state.warnings.isEmpty { return .orange }
        return .secondary
    }

    private var totalCount: Int {
        (state.errorMessage != nil ? 1 : 0) + state.warnings.count
    }

    var body: some View {
        if hasNotice && (selection ?? .dashboard) != .records {
            Button {
                showingPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bell.badge.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(noticeColor, .primary)
                    Text("\(totalCount)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(noticeColor)
                }
            }
            .help("有 \(totalCount) 条通知提醒")
            .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("通知提醒")
                            .font(.headline)
                        Text("\(totalCount)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(noticeColor, in: Capsule(style: .circular))
                        Spacer()
                        Button("全部清除") {
                            state.dismissError()
                            state.clearWarnings()
                            showingPopover = false
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Divider()

                    if let error = state.errorMessage {
                        noticeRow(text: error, symbol: "exclamationmark.octagon.fill", tint: .red)
                    }
                    if let warning = state.warnings.last {
                        noticeRow(text: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
                    }

                    Divider()

                    Button {
                        showingPopover = false
                        selection = .records
                    } label: {
                        HStack {
                            Text("前往消息中心查看全部")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .frame(width: 280)
            }
        }
    }

    private func noticeRow(text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 侧栏「日志」项上的未读数。独立视图：错误与告警变化只刷新这枚徽标。
private struct SidebarNoticeBadge: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let count = (state.errorMessage != nil ? 1 : 0) + state.warnings.count
        if count > 0 {
            let tint: Color = state.errorMessage != nil ? .red : .orange
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1)
                .background(tint.opacity(0.14), in: Capsule(style: .circular))
        }
    }
}

/// 侧栏底部紧凑状态条：接管状态 · 出站模式 · 当前节点，点击前往代理页。
private struct SidebarStatusFooter: View {
    @Environment(AppState.self) private var state
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Divider().opacity(0.55)

                HStack(spacing: 7) {
                    Circle()
                        .fill(state.statusTint)
                        .frame(width: 6.5, height: 6.5)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(state.statusText)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(state.outboundMode.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Text(state.selectedNode?.name ?? "未选择节点")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 3)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击前往代理页切换节点")
    }
}
