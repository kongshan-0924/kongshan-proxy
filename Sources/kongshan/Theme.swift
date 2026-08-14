import KongshanCore
import SwiftUI

/// 全局视觉常量与格式化工具。风格参考 Surge / Stash：克制配色、圆角卡片、等宽数字，无动效。
enum Theme {
    static let cardRadius: CGFloat = 14
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let pageFill = Color(nsColor: .windowBackgroundColor)

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

extension View {
    /// 卡片容器：卡面用 controlBackgroundColor（浅色下为白），配柔和投影浮在页面灰底上。
    /// 不用 `.background` / `.background.secondary`——这两者在浅色下几乎同色，分不出层次。
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(.quaternary.opacity(0.45), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
    }

    /// 页面底色：比卡片低一级，让卡片浮起来。
    func pageBackground() -> some View {
        background(Theme.pageFill)
    }
}

/// 卡片左上角的彩色圆角图标块。
struct IconBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(tint.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(tint)
            )
            .accessibilityHidden(true)
    }
}

/// 带色点的状态徽标，颜色之外同时保留文字，不单靠颜色表达状态。
struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }
}

/// 协议类型标签。
struct ProtocolTag: View {
    let value: ProxyProtocol

    var body: some View {
        Text(value.shortName)
            .font(.system(size: 9, weight: .bold))
            .kerning(0.3)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(Theme.protocolTint(value))
            .background(Theme.protocolTint(value).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
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

/// 各页面统一的标题区：标题 + 说明 + 右侧操作。
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
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

/// 通用搜索框：带搜索图标与一键清除按钮。
struct SearchField: View {
    @Binding var text: String
    var placeholder: String = "搜索…"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.quaternary.opacity(0.7), lineWidth: 0.5)
        )
    }
}

