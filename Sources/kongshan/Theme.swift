import AppKit
import KongshanCore
import SwiftUI

/// 视觉常量与格式化工具。
///
/// 取向是**原生 macOS**：系统语义色、系统文本样式（`.headline` / `.body` / `.caption`），
/// 容器一律用 `GroupBox` / `Form` / `List` / `Table` 这些系统件；不自绘投影、渐变图标块和
/// 圆角描边卡片——那一套是 web 仪表盘的语汇，放进 macOS 窗口里怎么调都像外来物。
/// 依据与逐页方案见 `docs/design/NATIVE_UI.md`。
enum Theme {
    /// 主窗口内容区底色。
    ///
    /// **不用默认的 `windowBackgroundColor`**：浅色模式下它是灰的（约 #ECECEC），
    /// 而页面上的卡片用的是系统 `GroupBox`——它本身也是浅灰。灰底摆灰卡，
    /// 两者明度差不到一档，整屏看上去就是一片平灰、没有层次
    ///（用户 2026-09-18 反馈「整体页面太灰了」）。
    ///
    /// 换成内容区专用的 `controlBackgroundColor`（浅色为白、深色为深灰），
    /// `GroupBox` 才立得起来。这也是 Xcode 检查器、邮件正文区用的那一档。
    /// 侧栏不受影响——它自己画半透明材质，不读窗口底色。
    static let windowBackgroundColor = NSColor.controlBackgroundColor
    static func delayColor(_ milliseconds: Int) -> Color {
        if milliseconds < 150 { return .green }
        if milliseconds < 350 { return .orange }
        return .red
    }

    static func bytes(_ value: Int64) -> String {
        AppState.formatBytes(value)
    }

    static func rate(_ value: Int64) -> String {
        AppState.formatRate(value)
    }

    /// 字节/速率为 0 时用「—」占位，避免空串导致布局跳动。
    static func bytesOrDash(_ value: Int64) -> String {
        let s = bytes(value)
        return s.isEmpty ? "—" : s
    }

    static func rateOrDash(_ value: Int64) -> String {
        let s = rate(value)
        return s.isEmpty ? "—" : s
    }

    /// 自检结论配色。与延迟/风险同一套语义。
    static func networkCheckTint(_ severity: NetworkCheckSeverity) -> Color {
        switch severity {
        case .ok: .green
        case .fixed: .orange
        case .problem: .red
        }
    }

    /// 风险等级配色。与延迟同一套语义：绿=好、橙=当心、红=差。
    static func riskTint(_ level: IPRiskLevel) -> Color {
        switch level {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    /// 「57% 中度风险 · 机房 IP」。没有标签时只留前半。
    static func riskSummary(_ info: IPReputationInfo) -> String {
        var parts: [String] = []
        if let score = info.fraudScore, let risk = info.risk {
            parts.append("\(score)% \(risk.title)")
        }
        if !info.labels.isEmpty { parts.append(info.labels.joined(separator: " · ")) }
        return parts.joined(separator: " · ")
    }

    static func protocolTint(_ value: ProxyProtocol) -> Color {
        switch value {
        case .shadowsocks: .blue
        case .trojan: .purple
        case .vmess: .teal
        case .vless: .mint
        case .hysteria2: .orange
        case .anytls: .indigo
        }
    }
}

extension ProxyMode {
    var displayName: String { self == .tun ? "TUN" : "系统代理" }
}

extension ProxyProtocol {
    /// 标签用短名，`shadowsocks` 全称会把节点行撑成两行。
    var shortName: String {
        switch self {
        case .shadowsocks: "SS"
        case .trojan: "TROJAN"
        case .vmess: "VMESS"
        case .vless: "VLESS"
        case .hysteria2: "HY2"
        case .anytls: "ANYTLS"
        }
    }
}

extension AppState {
    /// 出站模式绑定。仪表盘、代理页、托盘三处逐字相同，提到这里共用——
    /// 复制三份的代价不是行数，是「改了一处忘了另两处」。
    var outboundModeBinding: Binding<OutboundMode> {
        Binding(
            get: { self.outboundMode },
            set: { mode in Task { await self.setOutboundMode(mode) } }
        )
    }

    /// 测速方式绑定。设置页迁出后由代理页工具栏菜单使用。
    var speedTestMethodBinding: Binding<SpeedTestMethod> {
        Binding(
            get: { self.speedTestMethod },
            set: { method in Task { await self.setSpeedTestMethod(method) } }
        )
    }

    /// 接管方式（系统代理 / TUN）开关绑定。同样是三处逐字相同的复制。
    func takeoverModeBinding(_ mode: ProxyMode) -> Binding<Bool> {
        Binding(
            get: { self.activeModes.contains(mode) },
            set: { enabled in Task { await self.setMode(mode, enabled: enabled) } }
        )
    }

    /// 状态主色：运行中按模式区分，过渡态橙色，失败红色，关闭灰色。
    var statusTint: Color {
        switch status {
        case .on: activeMode == .tun ? .blue : .green
        case .starting, .stopping: .orange
        case .failed: .red
        case .off: .secondary
        }
    }
}

/// 容量条：左端 0、右端满，填充按比例取宽，颜色由调用方按语义给。
///
/// **不用 `ProgressView`**：macOS 上它的线性样式走系统强调色，`.tint(_:)` 不生效——
/// 出口分析的风险分「57%」是橙的、条却是灰的；配置页的用量 98% 也照样灰着。
/// 最显眼的元素反而不表达状态，等于没画。两条 Capsule 才能把颜色真正落上去。
struct CapacityBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * clamped, clamped > 0 ? 3 : 0))
            }
        }
        .frame(height: height)
    }
}

/// 用量条配色：过 85% 提醒、过 95% 告警。与延迟/风险同一套语义色。
extension Theme {
    static func usageTint(_ fraction: Double) -> Color {
        if fraction >= 0.95 { return .red }
        if fraction >= 0.85 { return .orange }
        return .accentColor
    }
}

/// 带色点的状态徽标。颜色之外同时保留文字，不单靠颜色表达状态。
/// 只有淡色填充，没有描边——邮件/访达的标签就是这个样子。
struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }
}

/// 协议类型标签。
struct ProtocolTag: View {
    let value: ProxyProtocol

    var body: some View {
        let tint = Theme.protocolTint(value)
        Text(value.shortName)
            .font(.caption2.weight(.semibold).monospaced())
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// 延迟数值，附带颜色分级；未测试与超时都有明确文字。
struct DelayLabel: View {
    let milliseconds: Int??

    var body: some View {
        switch milliseconds {
        case let .some(.some(value)):
            Text("\(value) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.delayColor(value))
        case .some(.none):
            Text("超时")
                .font(.caption)
                .foregroundStyle(.red)
        case .none:
            Text("—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// 节点排序选项。
enum NodeSortOption: String, CaseIterable, Identifiable {
    case defaultOrder = "默认排序"
    case latencyAscending = "延迟最低"
    case nameAscending = "名称排序"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .defaultOrder: "arrow.up.arrow.down"
        case .latencyAscending: "bolt.horizontal"
        case .nameAscending: "textformat.abc"
        }
    }
}
