import SwiftUI

/// 「日志」页：警告 / 运行事件 / 内核日志 三个小窗一页铺开。
///
/// 2026-11 统一重构为小窗风格：
/// 去掉旧版工具栏正中的三段切换，将同一条时间线的三种粒度
/// （用户需处理的警告、运行动作事件流水、内核原始日志）在一个页面内以小窗并列铺开，
/// 空间利用更充分，小窗内部各自滚动。
///
/// 保留 `Tab` 枚举与 `init(initialTab:)` 以兼容外部构造与快照测试。
struct RecordsPageView: View {
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
        LogsView()
    }
}
