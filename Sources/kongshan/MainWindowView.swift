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
        // 窗口大小只由用户和 window.minSize（820×560）决定，内容不反向撑窗口。
        // 默认 sizingOptions 会把页面的最小 / 理想尺寸变成窗口约束：日志页 200 条事件时把 640 高的窗口
        // 撑到 749（加页内顶栏后 801），2026-11-09 实测；各页内容都按窗口给的高度布局、长列表卡内滚动。
        hostingView.sizingOptions = []
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
    @FocusState private var sidebarFocused: Bool

    init(initialPage: SidebarPage = .dashboard) {
        _selection = State(initialValue: initialPage)
    }

    private var activePage: SidebarPage {
        selection ?? .dashboard
    }

    var body: some View {
        HStack(spacing: 0) {
            if !sidebarCollapsed {
                // 侧栏 188pt（960 窗口配套收窄）：与内容同底色，不再是独立的灰色栏。
                customSidebar
                    .frame(width: 188)
            }

            // 详情列顶到窗口上缘：各页的页内顶栏（PageTopBar）落在红绿灯那一行。
            detailCanvas
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.pageTopBarLeadingInset, sidebarCollapsed ? 96 : 0)
                .ignoresSafeArea(.container, edges: .top)
        }
        .background(Theme.canvasBackground)
        .tint(Theme.accent)
        // 窗口工具栏只放这一个固定项：项集合不随页面变，切页不触发 NSToolbar 重建（页面按钮在 PageTopBar）。
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

    // MARK: - 定制侧边栏（宽 188pt，与内容同底色 + 白底描边选中项 + 组间只留间距）

    private var customSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                // 项间距 2、组间距 12；第一项与红绿灯/工具栏下方保持 12pt 左右间距。
                VStack(alignment: .leading, spacing: 2) {
                    sidebarButton(.dashboard)

                    Spacer().frame(height: 10)

                    sidebarButton(.nodes)
                    sidebarButton(.policyGroups)
                    sidebarButton(.routing)

                    Spacer().frame(height: 10)

                    sidebarButton(.connections)
                    sidebarButton(.records)
                    sidebarButton(.diagnostics)
                    sidebarButton(.settings)
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }

            Spacer(minLength: 0)

            sidebarFooter
        }
        .background(Theme.sidebarFill.ignoresSafeArea(edges: .top))
        // 自绘侧栏没有系统 List 的方向键切换：点过侧栏后 ↑↓ 按侧栏顺序切页。
        .focusable()
        .focused($sidebarFocused)
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

    /// 导航项：32pt 高、圆角 7、实心 SF Symbol 13pt + 13pt 文字；
    /// 选中项白底 + 1.5pt 强调色描边 + 强调色图标文字（原型骨架）。
    private func sidebarButton(_ page: SidebarPage) -> some View {
        let isSelected = activePage == page
        return Button {
            selection = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    // 有实心变体的符号自动填实；没有变体的（network 等）保持原样。
                    .symbolVariant(.fill)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 13, height: 13, alignment: .center)

                Text(page.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if page == .records {
                    SidebarNoticeBadge()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 1.5)
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
struct DashboardToolbarMenu: View {
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("网络检测：探测出口（⌘R）、网络自检")
        .accessibilityLabel("网络检测")
    }
}


/// 侧栏「日志」项上的未读数。独立视图：错误与告警变化只刷新这枚徽标。
private struct SidebarNoticeBadge: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let count = (state.errorMessage != nil ? 1 : 0) + state.warnings.count
        if count > 0 {
            // 原型：橙色计数徽标；有错误时仍用红色强调更重的级别。
            NoticeCountBadge(count: count, style: state.errorMessage != nil ? Theme.danger : Theme.warningBadge)
        }
    }
}

/// 侧栏底部白色状态卡：第一行状态点 + 「接管方式 / 出站模式」，第二行「地区 节点名」+ 彩色延迟。
/// 点击前往代理页。
private struct SidebarStatusFooter: View {
    @Environment(AppState.self) private var state
    let onTap: () -> Void

    private var shortStatus: String {
        guard state.isOn else { return state.status == .off ? "已关闭" : state.statusText }
        if state.activeModes.isEmpty { return "未接管" }
        if state.activeModes.count > 1 { return "双接管" }
        return state.activeModes.contains(.tun) ? "TUN" : "系统代理"
    }

    private var statusStyle: Theme.SemanticColors {
        switch state.status {
        case .on: Theme.current
        case .starting, .stopping: Theme.warning
        case .failed: Theme.danger
        case .off: Theme.neutral
        }
    }

    /// 「美国 DMIT-洛杉矶 Reality」：有地区码时前缀地区中文名。
    private var nodeLine: String {
        guard let node = state.selectedNode else { return "未选择节点" }
        let code = state.nodeCatalog.metadataByNodeID[node.id]?.regionCode
            ?? NodeNameMetadata.parse(node.name).regionCode
        // 与菜单面板同一套规则：去国旗、港澳台简称、名字已含地区不重复前缀。
        return MenuBarPanelDirectory.nodeTitle(node.name, regionCode: code ?? "")
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusStyle.icon)
                        .frame(width: 7, height: 7)
                    Text(state.isOn ? "\(shortStatus) / \(state.outboundMode.displayName)" : shortStatus)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(nodeLine)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    SidebarFooterDelay()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .help("点击前往代理页切换节点")
    }
}

/// 状态卡第二行右侧的延迟：高频回填只刷新这一小块文字。
private struct SidebarFooterDelay: View {
    @Environment(AppState.self) private var state

    var body: some View {
        if let id = state.selectedNode?.id, let delay = state.delays[id] {
            // fixedSize：侧栏收窄到 188 后第二行更紧，延迟保持完整，节点名先截断。
            if let milliseconds = delay {
                Text("\(milliseconds)ms")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.delayColor(milliseconds))
                    .fixedSize()
            } else {
                Text("超时")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger.text)
                    .fixedSize()
            }
        }
    }
}
