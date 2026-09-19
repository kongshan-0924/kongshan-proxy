import AppKit
import KongshanCore
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @Environment(AppState.self) private var state
    @State private var selection: SidebarPage? = .dashboard
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                sidebarRow(.dashboard)
                // 两个组名各 3 项，扫一眼就知道该去哪。原先「其他」塞 6 项，
                // 那不是分组、是兜底。
                Section("流量") {
                    sidebarRow(.nodes)
                    sidebarRow(.policyGroups)
                    sidebarRow(.routing)
                }
                Section("排查") {
                    sidebarRow(.connections)
                    sidebarRow(.records)
                    sidebarRow(.diagnostics)
                }
                sidebarRow(.settings)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) { sidebarStatus }
        } detail: {
            Group {
                switch selection ?? .dashboard {
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NativeNoticeToolbarItem(selection: $selection)
                }
            }
            // 只喂给自诊断做归因，不参与渲染。CPU 异常记录里此前缺的正是这一条：
            // 只说得出"主线程在渲染"，说不出在渲染哪一页。
            .onAppear { state.noteVisiblePage((selection ?? .dashboard).title) }
            .onDisappear { state.noteVisiblePage(nil) }
            .onChange(of: selection) { _, page in
                state.noteVisiblePage((page ?? .dashboard).title)
            }
            // 空态按钮（「前往配置页」等）与 ⌘, 发来的跳转请求：切页、清号。
            //
            // `initial: true` 不能省：窗口**首次**打开时本视图刚被创建，而 ⌘, 是先建窗口、
            // 再发跳转请求——请求值很可能在第一次求值 body 之前就已写入，
            // 此时 `onChange` 看不到"变化"，窗口会停在仪表盘而不是设置页。
            .onChange(of: state.requestedPage, initial: true) { _, page in
                guard let page else { return }
                selection = page
                state.requestedPage = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
                .accessibilityLabel(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
            }
        }
        // ⌘1~⌘8 直接切页，与侧栏顺序一致。零尺寸透明按钮藏在背景里，
        // 只提供快捷键，不参与布局与渲染。
        .background {
            HStack(spacing: 0) {
                // 只给前 9 页绑 ⌘1~⌘9。第 10 页起不能再绑：`Character("10")` 不是单字符，
                // `Character(_:)` 会直接 trap——加一页就崩，且崩在启动路径上。
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

    private func sidebarRow(_ page: SidebarPage) -> some View {
        // 未读数用系统 `.badge`：与访达 / 邮件的侧栏一致，不再自绘胶囊。
        let noticeCount = page == .records
            ? (state.errorMessage != nil ? 1 : 0) + state.warnings.count
            : 0
        return Label(page.title, systemImage: page.symbol)
            .badge(noticeCount)
            .tag(page)
    }

    /// 侧栏底部常驻状态条，任何页面下都能看到当前接管方式与节点。
    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(state.statusTint)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.statusText)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(state.selectedNode?.name ?? "未选择节点")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}

/// 原生 macOS 工具栏通知组件。
/// 依托 Detail 视图的原生 Toolbar 渲染在窗口最右上角，拥有纯正系统质感与交互体验。
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
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
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
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(noticeColor, in: Capsule())
                        Spacer()
                        Button("全部清除") {
                            state.dismissError()
                            state.clearWarnings()
                            showingPopover = false
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
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
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .semibold))
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
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

