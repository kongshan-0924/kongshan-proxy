import AppKit
import KongshanCore
import SwiftUI

/// 视觉常量与格式化工具。
///
/// 中性表面组织信息，矿物青标识当前链路、选择与主操作。
/// 色值与配对依据见 `docs/design/20261106-style-redesign.md`（审核修订优先）。
enum Theme {
    private static func sRGB(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        let lightColor = sRGB(light)
        let darkColor = sRGB(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    // 原型令牌（`docs/design/20261109-prototype-ui.md`）：浅色值取原型 spec，深色按同一层次推出。
    private static let lightWindowBackground = sRGB(0xF5F5F7)
    private static let darkWindowBackground = sRGB(0x1C1C1E)

    static let windowBackgroundColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? darkWindowBackground : lightWindowBackground
    }
    static let canvasBackground = Color(nsColor: windowBackgroundColor)

    // NSColor 是唯一来源；SwiftUI 不再自行叠透明度生成表面。
    // 侧栏与内容同底色（原型骨架）：不再有独立的灰色侧栏。
    static let sidebarFillColor = windowBackgroundColor
    static let cardFillColor = dynamic(light: 0xFFFFFF, dark: 0x242427)
    // 输入框、分段轨道、图标块的浅灰实心底 ≈ 黑 4%。
    static let controlFillColor = dynamic(light: 0xEFF0F3, dark: 0x2E2E30)
    // 发丝描边 ≈ 黑 5%（侧栏状态卡等少数仍描边的位置）。
    static let cardStrokeColor = dynamic(light: 0xF0F0F2, dark: 0x38383B)
    // 胶囊按钮描边 = 黑 15%。
    static let controlStrokeColor = dynamic(light: 0xD9D9D9, dark: 0x545459)
    static let inputStrokeColor = dynamic(light: 0xD1D1D6, dark: 0x63666B)
    // 分隔线 = 黑 6%。
    static let separatorColor = dynamic(light: 0xEBEBED, dark: 0x39393D)
    static let textPrimaryColor = dynamic(light: 0x1D1D1F, dark: 0xF5F5F7)
    // 原型次文字 #86868B；深色提到 0x9A9AA0 保证卡片底上 ≥4.5:1。
    static let textSecondaryColor = dynamic(light: 0x86868B, dark: 0x9A9AA0)
    static let textTertiaryColor = dynamic(light: 0x9D9DA3, dark: 0x7E7E84)
    static let accentColor = dynamic(light: 0x0E7C72, dark: 0x2FB3A4)
    static let onAccentColor = dynamic(light: 0xFFFFFF, dark: 0x141414)
    // 选中浅底 = 强调色 5%（原型生效配置行 / 侧栏用白底时这里是强调浅底）。
    static let selectionFillColor = dynamic(light: 0xF2F8F7, dark: 0x1E3633)
    static let hoverFillColor = dynamic(light: 0xE9EAED, dark: 0x2B2B2E)
    static let pressedFillColor = dynamic(light: 0xE5E7EA, dark: 0x303033)
    static let accentHoverColor = dynamic(light: 0x0C6E65, dark: 0x3CC2B2)
    static let accentPressedColor = dynamic(light: 0x0A615A, dark: 0x28A394)

    static let sidebarFill = Color(nsColor: sidebarFillColor)
    static let cardFill = Color(nsColor: cardFillColor)
    static let controlFill = Color(nsColor: controlFillColor)
    static let cardStroke = Color(nsColor: cardStrokeColor)
    static let controlStroke = Color(nsColor: controlStrokeColor)
    static let inputStroke = Color(nsColor: inputStrokeColor)
    static let separator = Color(nsColor: separatorColor)
    static let textPrimary = Color(nsColor: textPrimaryColor)
    static let textSecondary = Color(nsColor: textSecondaryColor)
    static let textTertiary = Color(nsColor: textTertiaryColor)
    static let accent = Color(nsColor: accentColor)
    static let onAccent = Color(nsColor: onAccentColor)
    static let selectionFill = Color(nsColor: selectionFillColor)
    static let hoverFill = Color(nsColor: hoverFillColor)
    static let pressedFill = Color(nsColor: pressedFillColor)
    static let accentHover = Color(nsColor: accentHoverColor)
    static let accentPressed = Color(nsColor: accentPressedColor)

    struct SemanticColors {
        let textColor: NSColor
        let iconColor: NSColor
        let softColor: NSColor
        let solidColor: NSColor
        let onSolidColor: NSColor
        let text: Color
        let icon: Color
        let soft: Color
        let solid: Color
        let onSolid: Color

        init(text: NSColor, icon: NSColor, soft: NSColor, solid: NSColor, onSolid: NSColor) {
            textColor = text
            iconColor = icon
            softColor = soft
            solidColor = solid
            onSolidColor = onSolid
            self.text = Color(nsColor: text)
            self.icon = Color(nsColor: icon)
            self.soft = Color(nsColor: soft)
            self.solid = Color(nsColor: solid)
            self.onSolid = Color(nsColor: onSolid)
        }
    }

    /// 文字用深色（小字 ≥4.5:1）；图标、色条、状态点单独用更亮的 iconLight（图形只需 ≥3:1）。
    /// 文字与图形共用深琥珀时，风险条、状态点发暗发褐（审核方 2026-11-06 看截图后的修订）。
    private static func semantic(
        light: UInt32, iconLight: UInt32, dark: UInt32, softLight: UInt32, softDark: UInt32
    ) -> SemanticColors {
        let foreground = dynamic(light: light, dark: dark)
        return SemanticColors(text: foreground, icon: dynamic(light: iconLight, dark: dark),
                              soft: dynamic(light: softLight, dark: softDark),
                              solid: foreground, onSolid: onAccentColor)
    }

    // 浅色图标色在卡片 / 画布 / 控件底 / 按下底上的最低对比度：success 3.0、warning 3.5、danger 4.0、info 3.9（图形 ≥3:1）。
    // 上传蓝 / 下载绿 / 警告橙按原型（#0A84FF / #30A46C / #FF9500），文字仍用更深的配对保 ≥4.5:1。
    static let success = semantic(light: 0x22663D, iconLight: 0x30A46C, dark: 0x8CD6A0, softLight: 0xEAF4EC, softDark: 0x1D3927)
    static let warning = semantic(light: 0x805500, iconLight: 0xC77400, dark: 0xE7C16A, softLight: 0xFFF3DD, softDark: 0x3B321C)
    static let danger = semantic(light: 0xD70015, iconLight: 0xFF3B30, dark: 0xF0A0AC, softLight: 0xFCEBED, softDark: 0x41262D)
    static let info = semantic(light: 0x285F96, iconLight: 0x0A84FF, dark: 0x9EC6F0, softLight: 0xEAF1FA, softDark: 0x22354A)
    static let current = SemanticColors(text: accentColor, icon: accentColor, soft: selectionFillColor,
                                        solid: accentColor, onSolid: onAccentColor)
    static let neutral = SemanticColors(text: textSecondaryColor, icon: textSecondaryColor, soft: controlFillColor,
                                        solid: textSecondaryColor, onSolid: onAccentColor)

    /// 警告计数徽标的实心橙（侧栏「日志」计数）。正文/图标仍用 `warning`（更深的琥珀保文字对比度），
    /// 徽标是小块图形配白字，用原型橙 #FF9500 的加深版（浅色白字 ≈3.5:1，深色用系统亮橙）。
    static let warningBadge = SemanticColors(
        text: dynamic(light: 0xC77400, dark: 0xFF9F0A),
        icon: dynamic(light: 0xC77400, dark: 0xFF9F0A),
        soft: dynamic(light: 0xFFF3DD, dark: 0x3B321C),
        solid: dynamic(light: 0xC77400, dark: 0xFF9F0A),
        onSolid: onAccentColor
    )

    /// 铃铛上的未读红点：小块图形用原型红 #FF3B30（文字错误仍用 `danger.text`，对比度足够）。
    static let alertDotColor = dynamic(light: 0xFF3B30, dark: 0xFF453A)
    static let alertDot = Color(nsColor: alertDotColor)

    // 卡片：圆角 14、无描边、内边距 16（原型骨架）。
    static let cardRadius: CGFloat = 14
    static let pagePadding: CGFloat = 20
    static let cardGap: CGFloat = 16
    static let uploadTint = info.icon
    static let downloadTint = success.icon

    static func delayColor(_ milliseconds: Int) -> Color {
        delayStyle(milliseconds).text
    }

    static func delayStyle(_ milliseconds: Int) -> SemanticColors {
        if milliseconds < 150 { return success }
        if milliseconds < 350 { return warning }
        return danger
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
        case .ok: success.text
        case .fixed: warning.text
        case .problem: danger.text
        }
    }

    /// 风险等级配色。与延迟同一套语义：绿=好、橙=当心、红=差。
    /// 风险三档的成对样式：数值与文字用 `.text`，色条与圆点用 `.icon`。
    static func riskStyle(_ level: IPRiskLevel) -> SemanticColors {
        switch level {
        case .low: success
        case .medium: warning
        case .high: danger
        }
    }

    static func riskTint(_ level: IPRiskLevel) -> Color {
        switch level {
        case .low: success.text
        case .medium: warning.text
        case .high: danger.text
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
        _ = value
        return textSecondary
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

    /// 运行使用链路青；过渡、失败和关闭使用对应的可读语义色。
    var statusTint: Color {
        switch status {
        case .on: Theme.accent
        case .starting, .stopping: Theme.warning.text
        case .failed: Theme.danger.text
        case .off: Theme.textSecondary
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
                Capsule(style: .circular).fill(Theme.controlFill)
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
        if fraction >= 0.95 { return danger.icon }
        if fraction >= 0.85 { return warning.icon }
        return accent
    }
}

/// 带色点的状态徽标；文字、图标与不透明浅底必须成套使用。
struct StatusBadge: View {
    let text: String
    let style: Theme.SemanticColors

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(style.icon)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.text)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(style.soft, in: Capsule(style: .circular))
    }
}

/// 工具栏、弹层和侧栏共用同一实底配对，深色模式不强制白字。
struct NoticeCountBadge: View {
    let count: Int
    let style: Theme.SemanticColors

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(style.onSolid)
            .padding(.horizontal, 6)
            .frame(minHeight: 18)
            .background(style.solid, in: Capsule(style: .circular))
    }
}

/// 协议类型标签。
struct ProtocolTag: View {
    let value: ProxyProtocol

    var body: some View {
        let tint = Theme.protocolTint(value)
        Text(value.shortName)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// 延迟数值，附带颜色分级；未测试与超时都有明确文字。
struct DelayLabel: View {
    let milliseconds: Int??

    var body: some View {
        switch milliseconds {
        case let .some(.some(value)):
            Text("\(value) ms")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.delayColor(value))
        case .some(.none):
            Text("超时")
                .font(.system(size: 12))
                .foregroundStyle(Theme.danger.text)
        case .none:
            Text("—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
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

/// 卡片样式：白底 + 圆角 14、无描边、内边距 16（2026-11-09 原型骨架）。
/// 整个主窗口统一用它（各页在根上设置 `.groupBoxStyle`），各页的 `GroupBox` 不必各自调。
/// 不用投影也不用描边：画布与卡片的白/灰层次已足够分出层级。
struct CardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            configuration.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

/// 分段选择：圆角矩形轨道（黑 4%），选中块白底圆角 6（原型 2026-11-09；键盘焦点独立显示）。
/// 名字保留 CapsuleSegmentedPicker：调用方（仪表盘出站模式、流量范围、连接筛选）不用改。
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
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(PillButtonStyle(selection: isSelected))
                // 自绘按钮没有系统分段控件的选中语义，VoiceOver 要靠这个读出「已选择」。
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            Theme.separator.frame(height: 0.5)
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
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
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
    var accented = false
    /// 非 nil 时是分段选项；选中态不被 hover / pressed 的中性底覆盖。
    var selection: Bool? = nil

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent,
                       accented: accented, selection: selection)
    }
}

private struct PillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let accented: Bool
    let selection: Bool?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlSize) private var controlSize
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private var compact: Bool { controlSize == .small || controlSize == .mini }
    private var destructive: Bool { configuration.role == .destructive }
    /// 分段选项（selection != nil）用圆角矩形块，其余保持胶囊。
    private var isSegment: Bool { selection != nil }
    private var foreground: Color {
        if !isEnabled { return Theme.textTertiary }
        if prominent { return destructive ? Theme.danger.onSolid : Theme.onAccent }
        if destructive { return Theme.danger.text }
        if accented {
            return configuration.isPressed && colorScheme == .light ? Theme.accentPressed : Theme.accent
        }
        return Theme.textPrimary
    }
    private var fill: Color {
        if !isEnabled { return Theme.controlFill }
        if prominent {
            if destructive { return Theme.danger.solid }
            if configuration.isPressed { return Theme.accentPressed }
            return isHovering ? Theme.accentHover : Theme.accent
        }
        if selection == true { return Theme.cardFill }
        if configuration.isPressed { return Theme.pressedFill }
        if isHovering { return Theme.hoverFill }
        return selection == false ? Theme.controlFill : Theme.cardFill
    }

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13,
                          weight: prominent || selection == true ? .medium : .regular))
            .lineLimit(1)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, selection == nil ? (compact ? 4 : 5) : (compact ? 2 : 3))
            .frame(minWidth: 24, maxWidth: selection == nil ? nil : .infinity,
                   minHeight: (compact ? 24 : 28) - (selection == nil ? 0 : 4))
            .foregroundStyle(foreground)
            .background {
                if isSegment {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
                } else {
                    Capsule(style: .circular).fill(fill)
                }
            }
            .overlay {
                if isSegment {
                    // 分段块：无描边，选中态只靠白底与字重区分（原型）。
                    if isEnabled && isFocused {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                            .padding(-3)
                            .allowsHitTesting(false)
                    }
                } else {
                    capsuleOverlays
                }
            }
            .contentShape(contentShape)
            .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var capsuleOverlays: some View {
        if !isEnabled || !prominent {
            Capsule(style: .circular)
                .strokeBorder(!isEnabled ? Theme.cardStroke : Theme.controlStroke, lineWidth: 1)
        }
        if isEnabled && prominent && destructive && (isHovering || configuration.isPressed) {
            Capsule(style: .circular).inset(by: configuration.isPressed ? 3 : 2)
                .strokeBorder(Theme.danger.onSolid, lineWidth: 1)
        }
        if isEnabled && isFocused {
            Capsule(style: .circular).strokeBorder(Theme.accent, lineWidth: 2)
                .padding(-4)
                .allowsHitTesting(false)
        }
    }

    private var contentShape: AnyShape {
        isSegment
            ? AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            : AnyShape(Capsule(style: .circular))
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var pillProminent: PillButtonStyle { PillButtonStyle(prominent: true) }
    static var pillAccent: PillButtonStyle { PillButtonStyle(accented: true) }
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
    /// 调用方用 Theme.inputPrompt 构造占位文字；错误原因仍在字段旁显示。
    func inputField(isInvalid: Bool = false) -> some View {
        modifier(InputFieldModifier(isInvalid: isInvalid))
    }
}

extension Theme {
    static func inputPrompt(_ text: String) -> Text {
        Text(text).foregroundColor(textTertiary)
    }
}

private struct InputFieldModifier: ViewModifier {
    var isInvalid: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @GestureState private var isPressed = false

    private var compact: Bool { controlSize == .small || controlSize == .mini }
    private var fill: Color {
        if !isEnabled { return Theme.controlFill }
        if isPressed { return Theme.pressedFill }
        return isHovering ? Theme.hoverFill : Theme.controlFill
    }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
            .tint(Theme.accent)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 4 : 5)
            .frame(minHeight: compact ? 24 : 28)
            // 原型输入框：浅灰实心底、圆角 8、无描边；仅非法输入时描红。
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isInvalid {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.danger.icon, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                if isEnabled && isFocused {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .padding(-4)
                        .allowsHitTesting(false)
                }
            }
            .onHover { isHovering = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in
                pressed = true
            })
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
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Theme.canvasBackground)
        .toggleStyle(CardRowToggleStyle())
        .labeledContentStyle(CardRowLabeledContentStyle())
        .buttonStyle(.pill)
    }
}

/// 白卡分区，替代 `Section`。原型风格：卡内不画行分隔线，行间距 10。
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if expanded {
                rows
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                footer
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
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
                        .foregroundStyle(Theme.textSecondary)
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
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var rows: some View {
        // 原型卡片内不画行分隔线：行间距 10，两档系统一致。
        VStack(alignment: .leading, spacing: 10) {
            content
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

/// 卡片行里的开关：标签居左、开关居右（系统表单里的排法）。原型行正文 12pt 主文字色。
struct CardRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.accent)
        }
    }
}

/// 卡片行：标签用主文字色、实际值用次要色（原型「登录项状态 / 已启用」的排法）。
struct CardRowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 12)
            configuration.content
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}


// MARK: - 统一小组件（2026-11-05 界面统一）

/// 圆角图标块：名字以 emoji 开头时放 emoji，否则放 SF Symbol。代理页策略组、配置页配置项、规则页分区共用。
struct IconTile: View {
    var emoji: String?
    var symbol: String
    var size: CGFloat = 28
    var isActive = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                // 生效态用白块 + 强调色图标（原型：生效配置行的图标块是白底），
                // 放在浅强调底的行上才看得清；菜单栏面板里是画布灰底，同样成立。
                .fill(isActive ? Theme.cardFill : Theme.controlFill)
            if let emoji {
                Text(emoji).font(.system(size: size * 0.54))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size <= 22 ? 11 : size <= 32 ? 13 : 15, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// 拆出名字开头的 emoji（及其后空格）：返回 (emoji, 去掉 emoji 的标题)。没有 emoji 时 emoji 为 nil、标题原样。
    nonisolated static func split(_ name: String) -> (emoji: String?, title: String) {
        guard let first = name.first, let scalar = first.unicodeScalars.first else { return (nil, name) }
        let props = scalar.properties
        guard props.isEmojiPresentation || (props.isEmoji && scalar.value > 0x238C) else { return (nil, name) }
        let rest = name.dropFirst().drop { $0 == " " }
        return (String(first), rest.isEmpty ? name : String(rest))
    }
}

/// 卡片标题行：可选 13pt 灰色单色图标 + 标题（13pt 半粗）+ 次要说明（caption）+ 右侧操作。
/// 卡片内容上方统一用它。原型骨架：不再用图标方块（IconTile）。
struct CardHeader<Trailing: View>: View {
    let title: String
    var symbol: String?
    var detail: String?
    @ViewBuilder var trailing: Trailing

    init(_ title: String, symbol: String? = nil, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(detail)
            }
            Spacer(minLength: 8)
            trailing
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .frame(minHeight: Trailing.self == EmptyView.self ? 24 : 28)
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: String, symbol: String? = nil, detail: String? = nil) {
        self.init(title, symbol: symbol, detail: detail) { EmptyView() }
    }
}

/// 胶囊下拉选择：替代系统 `Picker` 的弹出按钮样式（灰底按钮放在白卡上发闷，与胶囊按钮不是一套）。
/// 外观与 `.pill` 按钮一致，右侧带上下箭头；选项多时仍是原生菜单。
struct PillMenuPicker<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    /// 最宽多少；nil 表示按文字宽度（空间不够时收缩并截断）。
    var maxWidth: CGFloat? = nil
    /// 胶囊铺满给它的宽度：菜单只按标签的理想宽度排版，名字很长时不铺满就会被挤成「“…）」。
    var fills = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @FocusState private var isFocused: Bool
    @State private var isHovering = false
    @GestureState private var isPressed = false

    private var compact: Bool { controlSize == .small || controlSize == .mini }
    private var fill: Color {
        if !isEnabled { return Theme.controlFill }
        if isPressed { return Theme.pressedFill }
        // 原型下拉选择：白底 + 黑 15% 描边，与次要胶囊按钮一致。
        return isHovering ? Theme.hoverFill : Theme.cardFill
    }

    var body: some View {
        // 胶囊由 SwiftUI 自己画（能铺满、能截断），上面盖一层透明的原生菜单负责弹出选项。
        // 直接把胶囊当 Menu 的标签不行：macOS 的 Menu 交给 AppKit 按钮按理想宽度排版，
        // 名字长了要么撑破小窗（fixedSize），要么被挤成「“…）」。
        HStack(spacing: 6) {
            Text(title(selection))
                .lineLimit(1)
                .truncationMode(.middle)
                // 不铺满时按文字宽度贴合，最多 maxWidth，超出截断。
                .frame(maxWidth: fills ? .infinity : maxWidth, alignment: .leading)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.textSecondary : Theme.textTertiary)
        }
        .font(.system(size: compact ? 12 : 13))
        .foregroundStyle(isEnabled ? Theme.textPrimary : Theme.textTertiary)
        .padding(.horizontal, compact ? 8 : 12)
        .padding(.vertical, compact ? 4 : 5)
        .frame(minHeight: compact ? 24 : 28)
        .background(fill, in: Capsule(style: .circular))
        .overlay(Capsule(style: .circular).strokeBorder(isEnabled ? Theme.controlStroke : Theme.cardStroke, lineWidth: 1))
        .overlay {
            if isEnabled && isFocused {
                Capsule(style: .circular).strokeBorder(Theme.accent, lineWidth: 2)
                    .padding(-4)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            Menu {
                Picker("", selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(title(option)).tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Color.clear
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .contentShape(Capsule(style: .circular))
            .focused($isFocused)
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($isPressed) { _, pressed, _ in
                pressed = true
            })
        }
        // 铺满时宽度听外面的；不铺满时贴合理想宽度（外层 frame(maxWidth:) 会贪婪地占满上限，把旁边的胶囊挤扁）。
        .fixedSize(horizontal: !fills, vertical: true)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title(selection))
    }
}

// MARK: - 小窗布局（2026-11-05：规则页起，各页统一成仪表盘那样的多个小窗）

/// 小窗页：画布底 + 四周留白的滚动容器。页面内容由若干 `TileGrid` / `TileCard` 组成。
/// 宽窗口不限宽：小窗按列铺开，正是要把横向空间用起来。
struct TilePage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardGap) {
                content
            }
            .padding(Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.canvasBackground)
        .buttonStyle(.pill)
    }
}

/// 小窗网格：按可用宽度自动排 1–3 列（每列至少 `minColumnWidth`），列等宽、顶端对齐。
/// 窄窗口自然退成单列，不会横向溢出。
struct TileGrid<Content: View>: View {
    var minColumnWidth: CGFloat = 320
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minColumnWidth), spacing: Theme.cardGap, alignment: .top)],
            alignment: .leading,
            spacing: Theme.cardGap
        ) {
            content
        }
    }
}

/// 小窗：固定高度的白卡。顶部标题行（图标块 + 标题 + 计数 + 右侧操作），
/// 可选的固定区（输入框、开关这类不随列表滚动的控件），下面是**卡内滚动**的列表。
/// 列表用 `LazyVStack`，几千条也只建可见的行。
struct TileCard<Header: View, Content: View, Trailing: View>: View {
    let title: String
    var symbol: String?
    var emoji: String?
    var detail: String?
    /// 整张小窗的高度；nil 表示随内容（用于表单类小窗）。
    var height: CGFloat? = 300
    @ViewBuilder var trailing: Trailing
    /// 标题行下面、列表上面的固定区；不需要时传 `EmptyView()`。
    @ViewBuilder var fixedHeader: Header
    @ViewBuilder var content: Content

    init(
        _ title: String,
        symbol: String? = nil,
        emoji: String? = nil,
        detail: String? = nil,
        height: CGFloat? = 300,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder fixedHeader: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.emoji = emoji
        self.detail = detail
        self.height = height
        self.trailing = trailing()
        self.fixedHeader = fixedHeader()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题行：13pt 灰色单色图标（或 emoji）+ 13pt 半粗标题，不用图标方块（原型骨架）。
            HStack(spacing: 8) {
                if let emoji {
                    Text(emoji).font(.system(size: 13))
                        .accessibilityHidden(true)
                }
                CardHeader(title, symbol: emoji == nil ? symbol : nil, detail: detail) { trailing }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if Header.self != EmptyView.self {
                fixedHeader
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }

            if height == nil {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) { content }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height)
        // 内容再宽也不许画出卡片：否则一个长名字就能让相邻小窗「连在一起」。
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

extension TileCard where Header == EmptyView {
    init(
        _ title: String, symbol: String? = nil, emoji: String? = nil, detail: String? = nil, height: CGFloat? = 300,
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content
    ) {
        self.init(title, symbol: symbol, emoji: emoji, detail: detail, height: height,
                  trailing: trailing, fixedHeader: { EmptyView() }, content: content)
    }
}

extension TileCard where Header == EmptyView, Trailing == EmptyView {
    init(
        _ title: String, symbol: String? = nil, emoji: String? = nil, detail: String? = nil, height: CGFloat? = 300,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title, symbol: symbol, emoji: emoji, detail: detail, height: height,
                  trailing: { EmptyView() }, fixedHeader: { EmptyView() }, content: content)
    }
}

/// 小窗里的一行：左图标（可选）+ 主文字 + 次要文字 + 右侧内容，行间发丝分隔。
/// 小窗列表统一用它，各页的行高、字号、分隔线才一致。
struct TileRow<Trailing: View>: View {
    var symbol: String?
    let title: String
    var subtitle: String?
    var monospaced = false
    var subtitleMonospaced = false
    var expandsText = false
    let showsDivider: Bool
    @ViewBuilder var trailing: Trailing
    @State private var isExpanded = false

    init(symbol: String? = nil, _ title: String, subtitle: String? = nil, monospaced: Bool = false,
         subtitleMonospaced: Bool = false, expandsText: Bool = false,
         showsDivider: Bool, @ViewBuilder trailing: () -> Trailing) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.monospaced = monospaced
        self.subtitleMonospaced = subtitleMonospaced
        self.expandsText = expandsText
        self.showsDivider = showsDivider
        self.trailing = trailing()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, design: monospaced ? .monospaced : .default))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(expandsText ? (isExpanded ? nil : 2) : 1)
                        .truncationMode(expandsText ? .tail : .middle)
                        .help(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: subtitleMonospaced ? .monospaced : .default))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(expandsText ? (isExpanded ? nil : 2) : 1)
                            .truncationMode(expandsText ? .tail : .middle)
                            .help(subtitle)
                    }
                    if expandsText {
                        Button(isExpanded ? "收起" : "展开全文") { isExpanded.toggle() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel(isExpanded ? "收起详细内容" : "展开详细内容")
                    }
                }
                Spacer(minLength: 8)
                trailing
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.vertical, 7)
            if showsDivider { Theme.separator.frame(height: 0.5) }
        }
    }
}

extension TileRow where Trailing == EmptyView {
    init(symbol: String? = nil, _ title: String, subtitle: String? = nil, monospaced: Bool = false,
         subtitleMonospaced: Bool = false, expandsText: Bool = false, showsDivider: Bool) {
        self.init(symbol: symbol, title, subtitle: subtitle, monospaced: monospaced,
                  subtitleMonospaced: subtitleMonospaced, expandsText: expandsText, showsDivider: showsDivider) { EmptyView() }
    }
}

/// 小窗列表空时的一行说明（不用大号 ContentUnavailableView，小窗里放不下也不好看）。
struct TileEmptyNote: View {
    var symbol: String? = nil
    let text: String

    init(symbol: String? = nil, text: String) {
        self.symbol = symbol
        self.text = text
    }

    init(_ text: String, symbol: String? = nil) {
        self.symbol = symbol
        self.text = text
    }

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
            }
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 16)
    }
}

/// 瀑布流小窗：列数同 `TileGrid`（按宽度 1–3 列、每列至少 `minColumnWidth`），但每个小窗放进**当前最矮的那一列**，
/// 而不是按行对齐。用于随内容高度的小窗（设置、诊断这类表单）：网格按行对齐时，矮卡下面会空出一大块。
// MARK: - 页内顶栏

/// 页内顶栏：各页的分段、按钮放在这里，与窗口红绿灯同一行。
///
/// 窗口是 fullSizeContentView，详情列顶部伸进标题栏高度带（`Theme.topBarHeight`），窗口工具栏只留固定的侧栏开关。
/// 原先每页各自声明 `.toolbar` / `.searchable` / `.navigationSubtitle`，切页时 AppKit 要拆掉重建整条工具栏，
/// 占切页耗时约三成（2026-11-09 iMac 采样）；页内顶栏是普通 SwiftUI 视图，随页面一起建，不牵动窗口工具栏。
/// 空白处保留拖动窗口与双击缩放（按系统「连按标题栏」设置）。
struct PageTopBar<Content: View>: View {
    @Environment(\.pageTopBarLeadingInset) private var leadingInset
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) { content }
            .controlSize(.regular)
            // 与原先窗口工具栏一致：图标按钮、悬停才显底色，菜单不画箭头。
            .labelStyle(.iconOnly)
            .buttonStyle(TopBarIconButtonStyle())
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(.leading, Theme.pagePadding + leadingInset)
            .padding(.trailing, Theme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .frame(height: Theme.topBarHeight)
            .padding(.bottom, Theme.topBarGap)
            .background(TopBarDragSurface())
    }
}

/// 顶栏图标按钮：28×28、圆角 7，悬停 / 按下才显底色（与系统工具栏按钮观感一致）。
struct TopBarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TopBarIconButtonBody(configuration: configuration)
    }

    private struct TopBarIconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundStyle(isEnabled ? Theme.textSecondary : Theme.textTertiary)
                .frame(minWidth: 28, minHeight: 28)
                .padding(.horizontal, 2)
                .background(configuration.isPressed ? Theme.pressedFill : (hovering && isEnabled ? Theme.hoverFill : .clear),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

extension Theme {
    /// 统一工具栏高度带（红绿灯所在那一行），页内顶栏与之等高。
    static let topBarHeight: CGFloat = 52
    /// 顶栏下方留的空隙。不能为 0：页面滚动视图的上沿一旦正好贴着工具栏高度带，macOS 26 会把它伸进带里、
    /// 盖一层滚动边缘效果视图，顶栏按钮与拖动全被它截走（2026-11-09 离屏命中测试：仪表盘、设置、诊断页）。
    static let topBarGap: CGFloat = 4
}

private struct PageTopBarLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 侧栏收起时详情列顶到窗口左缘，顶栏要给红绿灯和侧栏开关让位。
    var pageTopBarLeadingInset: CGFloat {
        get { self[PageTopBarLeadingInsetKey.self] }
        set { self[PageTopBarLeadingInsetKey.self] = newValue }
    }
}

extension View {
    /// 在页面上方加一条页内顶栏（见 `PageTopBar`）。主窗口里每一页都必须调用，没有按钮也要调：
    /// 详情列忽略了顶部安全区，不调用的页面内容会顶进红绿灯那一行。
    func pageTopBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        VStack(spacing: 0) {
            PageTopBar { bar() }
            self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// 顶栏空白处：按住拖动窗口，双击按系统设置缩放 / 最小化。
/// macOS 15 起用 SwiftUI 的 `WindowDragGesture`：NSViewRepresentable 放在背景里时，
/// NSHostingView 的命中测试不会把点击交给它（2026-11-09 离屏命中探针），拖不动。
private struct TopBarDragSurface: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    if let window = NSApp.keyWindow { performTitlebarDoubleClick(window) }
                })
                .allowsWindowActivationEvents(true)
        } else {
            WindowDragArea()
        }
    }
}

/// 双击标题栏的系统行为（系统设置 → 桌面与程序坞 → 连按窗口标题栏）。
@MainActor
private func performTitlebarDoubleClick(_ window: NSWindow) {
    switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
    case "Minimize": window.performMiniaturize(nil)
    case "None": break
    default: window.performZoom(nil)
    }
}

/// macOS 14 的退路：AppKit 视图自己处理按下拖动与双击。
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                performTitlebarDoubleClick(window)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// 顶栏 / 卡片标题行里的搜索框：放大镜 + 输入 + 清除，⌘F 聚焦、Esc 清空。
struct TopBarSearchField: View {
    @Binding var text: String
    let prompt: String
    var width: CGFloat = 200
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onExitCommand { text = ""; focused = false }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: 28)
        .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            Button("搜索") { focused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt)
    }
}

/// 卡内列表：内容少时贴合自身高度，超过可用高度（或 `maxHeight`）后在卡内滚动。
///
/// 只建一份懒加载内容，按实测内容高度限高。不用 `ViewThatFits`：它会先把「不滚动」那份整列表
/// 非懒加载地建好、量一遍，再建滚动那份——300 个成员时代理页切页从约 300 ms 涨到 1 s，
/// 每次延迟刷新也要重量一遍（2026-11-09 用户反馈切页变慢，iMac 基准实测）。
/// `estimatedHeight` 是首帧量出实高前的估值，估得准就不会有首帧跳动。
struct HuggingScrollStack<Content: View>: View {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 0
    var maxHeight: CGFloat = .infinity
    var estimatedHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var measuredHeight: CGFloat?

    var body: some View {
        let height = min(measuredHeight ?? estimatedHeight, maxHeight)
        ScrollView {
            LazyVStack(alignment: alignment, spacing: spacing) { content }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { newValue in
                    // 只在变化超过半点时回写，避免浮点抖动触发无谓的重排。
                    if abs((measuredHeight ?? -1) - newValue) > 0.5 { measuredHeight = newValue }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.automatic)
        .frame(idealHeight: height, maxHeight: height)
    }
}

struct TileMasonry: Layout {
    var minColumnWidth: CGFloat = 320
    /// 最多几列：只有两三个小窗的页面限 2 列，宽窗口里才不会空出整整一列。
    var maxColumns = 3
    var spacing: CGFloat = Theme.cardGap

    private func columnCount(for width: CGFloat) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        return max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (columnWidth: CGFloat, origins: [CGPoint], height: CGFloat) {
        let columns = columnCount(for: width)
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        var origins: [CGPoint] = []
        for subview in subviews {
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let size = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil))
            let y = heights[column] == 0 ? 0 : heights[column] + spacing
            origins.append(CGPoint(x: CGFloat(column) * (columnWidth + spacing), y: y))
            heights[column] = y + size.height
        }
        return (columnWidth, origins, heights.max() ?? 0)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        return CGSize(width: width, height: arrange(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(width: layout.columnWidth, height: nil)
            )
        }
    }
}
