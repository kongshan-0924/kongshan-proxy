import SwiftUI

/// 侧栏页面。
///
/// 2026-09-17 信息架构重构：10 页 → 8 页，⌘1~⌘8 全覆盖（原先第 10 页拿不到快捷键）。
/// 合并依据见 `docs/design/NATIVE_UI.md` 的「信息架构」一节：
/// - `sharing` 并入 `connections`：共享的「已接入设备」与连接表回答同一个问题——此刻谁在用我的网络。
/// - `messages` 并入 `records`：警告、运行事件、内核输出是同一条时间线的三个粒度。
/// - `exitAnalysis` 扩为 `diagnostics`：出口分析 + 网络自检 + 规则命中测试 + 深度诊断，
///   把原先散在六处的排查能力收进一页。
///
/// internal 而非 private：`shortcutKey(at:)` 的越界保护断了会**直接崩在主窗口构建路径**上
/// （`Character("10")` 会 trap），必须能被测试直接覆盖。
enum SidebarPage: String, CaseIterable, Identifiable {
    case dashboard
    case nodes
    case policyGroups
    case routing
    case connections
    case records
    case diagnostics
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .nodes: "配置"
        case .policyGroups: "代理"
        case .routing: "规则"
        case .connections: "连接"
        case .records: "日志"
        case .diagnostics: "诊断"
        case .settings: "设置"
        }
    }

    /// ⌘1~⌘9。超出的页不绑快捷键——`Character("10")` 不是单字符，构造会 trap。
    /// 重构后只有 8 页，全部拿得到快捷键；这条保护仍留着，因为加页是常有的事。
    /// internal 而非 private：这条性质断了会**直接崩在启动路径**上，需回归覆盖。
    static func shortcutKey(at index: Int) -> KeyEquivalent? {
        guard (0..<9).contains(index) else { return nil }
        return KeyEquivalent(Character("\(index + 1)"))
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.needle"
        case .nodes: "square.stack.3d.up"
        case .policyGroups: "network"
        case .routing: "arrow.triangle.branch"
        case .connections: "point.3.filled.connected.trianglepath.dotted"
        case .records: "doc.plaintext"
        case .diagnostics: "stethoscope"
        case .settings: "gearshape"
        }
    }
}
