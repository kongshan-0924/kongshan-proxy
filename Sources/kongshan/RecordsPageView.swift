import SwiftUI

/// 「日志」页：警告 / 事件 / 内核三个分段。
///
/// 2026-09-17 把原「消息」页并进来。三者是同一条时间线的三个粒度——
/// 警告是要用户处理的、事件是接管动作的流水、内核是最原始的输出。
/// 分成两页的后果是排查时要在两处找同一件事，而且两页各有一个分段控件。
///
/// 容器只提供 `.principal` 分段与 `.navigationTitle`；副标题、搜索、其余工具栏项
/// 全部由子视图自己声明——这样钉死子视图结构的测试（`RuntimeEventDetailTests`、
/// `LogsViewGroupingTests`、`NativeChromeGuardTests` 的 `.searchable` 名单）一条都不用改。
struct RecordsPageView: View {
    /// 外部指定初始分段：全局铃铛与仪表盘的跳转要直接落到「警告」。
    init(initialTab: Tab = .warnings) {
        _tab = State(initialValue: initialTab)
    }

    enum Tab: String, CaseIterable {
        case warnings = "警告"
        case events = "事件"
        case kernel = "内核"
    }

    @State private var tab: Tab

    var body: some View {
        // **结构化 if 而不是 ZStack 常驻**：内核分段的日志流订阅挂在 LogsView 的
        // onAppear/onDisappear 上，ZStack 会让三个分段同时存活，订阅永不释放。
        Group {
            switch tab {
            case .warnings: MessagesView(tab: messagesTab)
            case .events: MessagesView(tab: messagesTab)
            case .kernel: LogsView()
            }
        }
        .navigationTitle("日志")
        .toolbar {
            // 分段切换放工具栏正中：访达的视图切换器就在这个位置。
            ToolbarItem(placement: .principal) {
                Picker("记录类型", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    /// 把三段的容器状态映射成 MessagesView 的两段。写回时只认它自己的两个值，
    /// 内核分段不会经由这里切换（switch 已经把它分走了）。
    private var messagesTab: Binding<MessagesView.Tab> {
        Binding(
            get: { tab == .events ? .events : .warnings },
            set: { tab = $0 == .events ? .events : .warnings }
        )
    }
}
