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
    /// 主窗口内容区（画布）底色：极浅冷灰（#F2F3F6）。
    ///
    /// 2026-10-23 用户反馈「整体太暗、像置灰失焦」。根因是此前画布纯白、卡片微灰
    ///（primary 0.035）——卡片比画布暗，整屏看着像蒙了一层灰。恢复正常层次：
    /// **画布用极浅冷灰、卡片纯白浮起**（卡片亮于画布），画面通透不发灰。
    /// 深色模式画布深灰、卡片比它再亮一档。
    static let windowBackgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.110, green: 0.118, blue: 0.133, alpha: 1)
            : NSColor(srgbRed: 0.949, green: 0.953, blue: 0.965, alpha: 1)
    }

    /// 内容区画布底色：与 windowBackgroundColor 同步。
    static let canvasBackground = Color(nsColor: windowBackgroundColor)

    /// 侧边栏冷银灰底色（#E8EBF0），比画布略深一档以分清区域，屏蔽系统桌面透出的暖黄杂质。
    static let sidebarFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.068, green: 0.075, blue: 0.090, alpha: 1)
            : NSColor(srgbRed: 0.910, green: 0.921, blue: 0.941, alpha: 1)
    })

    /// 卡片（`GroupBox`）的底与描边。
    ///
    /// 卡片纯白浮在浅灰画布上（深色模式比画布亮一档），描边用发丝线划清边界。
    /// 用动态 NSColor 而不是 primary 透明度：透明度会让卡片吃画布色、始终比画布暗。
    static let cardFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.165, green: 0.173, blue: 0.192, alpha: 1)
            : NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    })
    static let cardStroke = Color.primary.opacity(0.12)
    static let cardRadius: CGFloat = 10

    /// 上传/下载速率语义色。仪表盘速率列、图例、菜单栏弹窗三处原先各自硬编码
    /// 蓝/绿，归到一处：改配色只动这里。
    static let uploadTint = Color.blue
    static let downloadTint = Color.green

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
            // 切换期间显示目标位置：开关点下去就停在那里，而不是弹回旧位置、等几秒再跳过去。
            get: { (self.modeTransitionTarget ?? self.activeModes).contains(mode) },
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
                Capsule(style: .circular).fill(.quaternary)
                Capsule(style: .circular)
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
        .background(tint.opacity(0.12), in: Capsule(style: .circular))
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

/// 卡片样式：浅底 + 发丝描边 + 圆角。整个主窗口统一用它（`MainWindowView` 在根上设置），
/// 各页的 `GroupBox` 不必各自调。不用投影：描边已足够分出层次，投影在浅色底上反而发脏。
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(.headline)
            configuration.content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
        )
    }
}

/// 胶囊分段选择器：浅灰底长条 + 纯白浮起选中块，与侧栏选区同一套视觉语言。
///
/// 替代系统 `.pickerStyle(.segmented)`——灰底分段胶囊放在白卡上发闷、边缘参差，
/// 和白卡/浅灰画布的层次不搭（用户 2026-10-23 圈出「这种 UI 太丑了」）。
/// 选中块纯白浮起加发丝描边，未选中透明，和卡片浮起、侧栏选区呼应。
struct CapsuleSegmentedPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.callout)
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .contentShape(Capsule(style: .circular))
                        .background {
                            if isSelected {
                                Capsule(style: .circular)
                                    .fill(Theme.cardFill)
                                    .overlay(Capsule(style: .circular).strokeBorder(Theme.cardStroke, lineWidth: 1))
                            }
                        }
                }
                .buttonStyle(.plain)
                // 自绘按钮没有系统分段控件的选中语义，VoiceOver 要靠这个读出「已选择」。
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.canvasBackground, in: Capsule(style: .circular))
        .accessibilityElement(children: .contain)
    }
}


/// 页面底部状态条：一行说明（计数、状态）+ 可选右侧操作，类似访达窗口底部的「12 项」。
///
/// 主窗口隐藏了标题栏，`.navigationSubtitle` 里的统计不再显示；需要常驻的那几项挪到这里。
/// 全 App 的底栏统一用它：自带分隔线、画布底、16/8 内边距，不再各页各写一套。
struct PageStatusBar<Trailing: View>: View {
    let text: String
    var symbol: String?
    @ViewBuilder var trailing: Trailing

    init(_ text: String, symbol: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Group {
                    if let symbol {
                        Label(text, systemImage: symbol)
                    } else {
                        Text(text)
                    }
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .monospacedDigit()
                Spacer(minLength: 8)
                trailing
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.canvasBackground)
        }
    }
}

extension PageStatusBar where Trailing == EmptyView {
    init(_ text: String, symbol: String? = nil) {
        self.init(text, symbol: symbol) { EmptyView() }
    }
}

// MARK: - 按钮

/// 全 App 统一按钮：白色胶囊 + 发丝描边（与胶囊选择器的选中块、侧栏选中项同一语言）；
/// 主操作用强调色填充。各页在**内容层**（`.toolbar` 之前）挂 `.buttonStyle(.pill)`，
/// 工具栏与菜单里的按钮不受影响；需要链接/图标样式的按钮仍显式写 `.link` / `.borderless` / `.plain`。
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(prominent ? .medium : .regular))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color.accentColor : Theme.cardFill, in: Capsule(style: .circular))
            .overlay {
                if !prominent {
                    Capsule(style: .circular).strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .circular))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
}

extension View {
    /// 弹层统一外观：胶囊按钮 + 画布底色（弹层是独立窗口，默认系统灰与卡片表单的画布色不一致）。
    func sheetChrome() -> some View {
        buttonStyle(.pill)
            .background(Theme.canvasBackground)
    }
}

// MARK: - 输入框

extension View {
    /// 全 App 统一输入框：白底 + 发丝描边 + 圆角 7，与卡片同一层次。
    /// 系统没有公开的自定义 `TextFieldStyle` 接口，所以用 `.plain` 加外框实现。
    func inputField() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            )
    }
}

// MARK: - 卡片表单

/// 替代页面里的 `Form(.grouped)`：macOS 分组表单的分区底色是系统固定的半透明灰，
/// `listRowBackground` 加在哪一层都不生效（2026-10-24 离屏实测），与仪表盘白卡永远是两套。
/// 用法与 `Form` 相同：里面放 `CardSection`；开关、`LabeledContent` 自动排成「左标签、右控件」。
struct CardForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvasBackground)
        .toggleStyle(CardRowToggleStyle())
        .labeledContentStyle(CardRowLabeledContentStyle())
        .buttonStyle(.pill)
    }
}

/// 白卡分区，替代 `Section`。行与行之间自动加分隔线（macOS 15 起；macOS 14 只留行间距）。
struct CardSection<Content: View, Header: View, Footer: View>: View {
    private let content: Content
    private let header: Header
    private let footer: Footer
    private let isExpanded: Binding<Bool>?

    init(
        isExpanded: Binding<Bool>? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder header: () -> Header,
        @ViewBuilder footer: () -> Footer
    ) {
        self.isExpanded = isExpanded
        self.content = content()
        self.header = header()
        self.footer = footer()
    }

    private var expanded: Bool { isExpanded?.wrappedValue ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerView
            if expanded {
                rows
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 0.5)
                    )
                footer
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        if let isExpanded {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(width: 12)
                    header
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
        } else {
            header
                .font(.headline)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var rows: some View {
        if #available(macOS 15.0, *) {
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                        if index > 0 { Divider() }
                        subview
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.vertical, 10)
        }
    }
}

extension CardSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension CardSection where Header == Text {
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { Text(title) }, footer: footer)
    }
}

extension CardSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(content: content, header: { EmptyView() }, footer: { EmptyView() })
    }
}

extension CardSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}

extension CardSection where Footer == EmptyView {
    init(isExpanded: Binding<Bool>? = nil, @ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(isExpanded: isExpanded, content: content, header: header, footer: { EmptyView() })
    }
}

/// 卡片行里的开关：标签居左、开关居右（系统表单里的排法）。
struct CardRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// 卡片行里的 `LabeledContent`：标签居左、内容居右，内容用次要色。
struct CardRowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
        }
    }
}
