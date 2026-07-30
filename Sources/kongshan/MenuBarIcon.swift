import AppKit
import KongshanCore

/// 菜单栏图标的绘制。
///
/// 为什么自己画而不是用 SF Symbols：菜单栏图标要表达"三种接管状态"，而系统符号里没有
/// 一组语义连贯、轮廓又足够接近的三连图；此前用 `shield.slash` / `shield.fill` /
/// `network.badge.shield.half.filled` 拼，三个图形宽度和视觉重量都不一致，切换时会跳。
///
/// 关键约束是**模板图标**（`isTemplate = true`）：菜单栏会把图像整个染成单色，
/// 所以颜色一律失效，状态只能靠**形状与不透明度**表达。这也是为什么"开启"不是变绿，
/// 而是从空心线稿变成实心。
/// `@MainActor`：绘制与缓存都只发生在菜单栏 label 求值时，本就在主线程；
/// 标上它比给缓存加锁更诚实——这里根本不存在并发访问。
@MainActor
enum MenuBarIcon {
    enum State {
        case off
        case systemProxy
        case tun
    }

    /// 菜单栏标准图标尺寸。glyph 画在 18×18 里，四周自带一点呼吸空间。
    private static let canvas = NSSize(width: 18, height: 18)

    /// 绘制有成本（每次状态变化都会重画），而组合只有 3×3 种，直接全缓存。
    private static var cache: [String: NSImage] = [:]

    static func image(style: MenuBarIconStyle, state: State) -> NSImage {
        let key = "\(style.rawValue)-\(state)"
        if let cached = cache[key] { return cached }

        let image = NSImage(size: canvas, flipped: false) { rect in
            draw(style: style, state: state, in: rect)
            return true
        }
        // 必须置 template：否则深色菜单栏下图标是黑的、菜单展开高亮时也不会反白。
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// 图标 + 两行速率，合成为**一张模板图**。
    ///
    /// 为什么不用 SwiftUI 的 `HStack { Image; VStack { Text; Text } }`：MenuBarExtra 的 label
    /// 会套用系统菜单栏字体并把内容压成一行——真机上试过，自定义字号不生效、第二行直接不见。
    /// 自己画成一张图就完全可控：字号、行距、对齐、模板染色都是确定的。
    static func statusImage(
        style: MenuBarIconStyle,
        state: State,
        uploadText: String,
        downloadText: String
    ) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            // 模板图只看 alpha，颜色随便给个不透明的即可。
            .foregroundColor: NSColor.black
        ]
        let up = NSAttributedString(string: "↑\(uploadText)", attributes: attributes)
        let down = NSAttributedString(string: "↓\(downloadText)", attributes: attributes)
        let textWidth = ceil(max(up.size().width, down.size().width))

        let iconWidth = canvas.width
        let gap: CGFloat = 3
        let total = NSSize(width: iconWidth + gap + textWidth, height: canvas.height)

        let image = NSImage(size: total, flipped: false) { rect in
            draw(style: style, state: state, in: NSRect(origin: .zero, size: canvas))
            // 两行竖排，右对齐。行高压到 8.5 让两行正好落在 18pt 内。
            let x = iconWidth + gap
            up.draw(at: NSPoint(x: x + textWidth - ceil(up.size().width), y: rect.height / 2 + 0.5))
            down.draw(at: NSPoint(x: x + textWidth - ceil(down.size().width), y: rect.height / 2 - 9))
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func draw(style: MenuBarIconStyle, state: State, in rect: NSRect) {
        // 关闭态整体压淡。模板图标用 alpha 通道当遮罩，所以降低 alpha 就是"变淡"，
        // 这是菜单栏里表达"未启用"的通行做法（系统的蓝牙/隔空投送都是这个路子）。
        let alpha: CGFloat = state == .off ? 0.42 : 1
        NSColor.black.withAlphaComponent(alpha).setStroke()
        NSColor.black.withAlphaComponent(alpha).setFill()

        switch style {
        case .peak: drawPeak(state: state, in: rect)
        case .valley: drawValley(state: state, in: rect)
        case .shield: drawShield(state: state, in: rect)
        }

        // TUN 额外加一个实心点。TUN 是"接管整台机器"的强状态，值得一个独立标记；
        // 点画在右上角的空处，不与山脊轮廓重叠。
        if state == .tun {
            let dot = NSBezierPath(ovalIn: NSRect(x: rect.maxX - 5.4, y: rect.maxY - 5.4, width: 3.6, height: 3.6))
            dot.fill()
        }
    }

    // MARK: - 三种样式

    /// 双峰山脊线稿。与 App 图标同源。
    private static func drawPeak(state: State, in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 1.5, y: rect.minY + 4.5))
        path.line(to: NSPoint(x: rect.minX + 6.4, y: rect.maxY - 4.2))
        path.line(to: NSPoint(x: rect.minX + 9.2, y: rect.minY + 8.2))
        path.line(to: NSPoint(x: rect.minX + 11.6, y: rect.minY + 10.6))
        path.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY + 4.5))
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if state == .off {
            path.stroke()
        } else {
            // 开启态封口填实：线稿 → 实心是最容易在 16pt 下分辨的变化。
            let filled = path.copy() as! NSBezierPath
            filled.line(to: NSPoint(x: rect.maxX - 1.5, y: rect.minY + 3.2))
            filled.line(to: NSPoint(x: rect.minX + 1.5, y: rect.minY + 3.2))
            filled.close()
            filled.fill()
        }
    }

    /// 山谷 + 通道。中间凹下去，轮廓起伏最大。
    private static func drawValley(state: State, in rect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 1.4, y: rect.minY + 4.2))
        path.line(to: NSPoint(x: rect.minX + 5.6, y: rect.maxY - 3.8))
        path.line(to: NSPoint(x: rect.midX, y: rect.minY + 7.4))
        path.line(to: NSPoint(x: rect.maxX - 5.6, y: rect.maxY - 3.8))
        path.line(to: NSPoint(x: rect.maxX - 1.4, y: rect.minY + 4.2))
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        if state == .off {
            path.stroke()
        } else {
            let filled = path.copy() as! NSBezierPath
            filled.line(to: NSPoint(x: rect.maxX - 1.4, y: rect.minY + 3))
            filled.line(to: NSPoint(x: rect.minX + 1.4, y: rect.minY + 3))
            filled.close()
            filled.fill()
        }
    }

    /// 盾形外框 + 内部山峰。
    private static func drawShield(state: State, in rect: NSRect) {
        let shield = NSBezierPath()
        let top = NSPoint(x: rect.midX, y: rect.maxY - 1.6)
        shield.move(to: top)
        shield.line(to: NSPoint(x: rect.maxX - 2.6, y: rect.maxY - 4.6))
        shield.line(to: NSPoint(x: rect.maxX - 2.6, y: rect.minY + 7.2))
        shield.curve(
            to: NSPoint(x: rect.midX, y: rect.minY + 1.6),
            controlPoint1: NSPoint(x: rect.maxX - 2.6, y: rect.minY + 4.4),
            controlPoint2: NSPoint(x: rect.midX + 3.4, y: rect.minY + 2.6)
        )
        shield.curve(
            to: NSPoint(x: rect.minX + 2.6, y: rect.minY + 7.2),
            controlPoint1: NSPoint(x: rect.midX - 3.4, y: rect.minY + 2.6),
            controlPoint2: NSPoint(x: rect.minX + 2.6, y: rect.minY + 4.4)
        )
        shield.line(to: NSPoint(x: rect.minX + 2.6, y: rect.maxY - 4.6))
        shield.close()
        shield.lineWidth = 1.6
        shield.lineJoinStyle = .round
        shield.stroke()

        // 内部山峰只在开启态出现：盾是"有防护能力"，峰是"正在生效"。
        guard state != .off else { return }
        let peak = NSBezierPath()
        peak.move(to: NSPoint(x: rect.minX + 5.2, y: rect.minY + 6.6))
        peak.line(to: NSPoint(x: rect.minX + 7.6, y: rect.minY + 10.4))
        peak.line(to: NSPoint(x: rect.minX + 9.1, y: rect.minY + 8.6))
        peak.line(to: NSPoint(x: rect.minX + 10.4, y: rect.minY + 10.1))
        peak.line(to: NSPoint(x: rect.maxX - 5.2, y: rect.minY + 6.6))
        peak.close()
        peak.fill()
    }
}
