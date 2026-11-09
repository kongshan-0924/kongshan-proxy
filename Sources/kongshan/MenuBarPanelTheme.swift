import AppKit
import SwiftUI

// MARK: - 菜单面板专用颜色

extension Theme {
    private static func menuPanelColor(
        light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1
    ) -> Color {
        func color(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                    green: CGFloat((hex >> 8) & 255) / 255,
                    blue: CGFloat(hex & 255) / 255, alpha: alpha)
        }
        let lightColor = color(light, lightAlpha)
        let darkColor = color(dark, darkAlpha)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        })
    }

    /// 只给离屏快照垫底用；真实面板底板是系统材质。
    static let menuPanelBackground = menuPanelColor(light: 0xFFFFFF, dark: 0x242427)
    static let menuPanelHover = menuPanelColor(light: 0, dark: 0xFFFFFF, lightAlpha: 0.03, darkAlpha: 0.08)
    static let menuPanelPrimary = menuPanelColor(light: 0x1D1D1F, dark: 0xECECEF)
    static let menuPanelSecondary = menuPanelColor(light: 0x86868B, dark: 0x98989E)
    static let menuPanelStroke = menuPanelColor(light: 0, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.15)
    static let menuPanelSeparator = menuPanelColor(light: 0, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
    static let menuPanelAccent = menuPanelColor(light: 0x0E7C72, dark: 0x30D158)
    static let menuPanelGreen = menuPanelColor(light: 0x248A3D, dark: 0x30D158)
    static let menuPanelYellow = menuPanelColor(light: 0xC58A00, dark: 0xFFD60A)
    static let menuPanelRed = menuPanelColor(light: 0xFF3B30, dark: 0xFF453A)
    static let menuPanelSwitchOff = menuPanelColor(light: 0xE5E5EA, dark: 0x636366)
    static let menuPanelKnob = menuPanelColor(light: 0xFFFFFF, dark: 0xFFFFFF)
    static let menuPanelTileOn = menuPanelColor(light: 0x0E7C72, dark: 0x30D158, lightAlpha: 0.1, darkAlpha: 0.2)
    static let menuPanelTileOff = menuPanelColor(light: 0xF5F5F7, dark: 0x39393D)
    static let menuPanelSelection = menuPanelColor(light: 0x0E7C72, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)

    static func menuPanelDelayColor(_ milliseconds: Int) -> Color {
        // 复用语义分级，避免菜单与主窗口在边界值上给出不同的健康判断。
        let style = delayStyle(milliseconds)
        if style.textColor == success.textColor { return menuPanelGreen }
        if style.textColor == warning.textColor { return menuPanelYellow }
        return menuPanelRed
    }
}

/// 菜单面板尺寸（2026-11-09 用户：「整体有点大，稍微调小一些」）：在原型 300 宽 / 30 行高基础上整体约缩到 0.9。
/// 主面板、子面板、控制器的高度计算都从这里取，改一处即可整体缩放。
enum MenuBarPanelMetrics {
    static let width: CGFloat = 272
    static let subWidth: CGFloat = 236
    static let mainRadius: CGFloat = 12; static let subRadius: CGFloat = 10
    static let padding: CGFloat = 7
    static let separatorInset: CGFloat = 7
    static let headerHeight: CGFloat = 40
    static let tileSize: CGFloat = 28
    static let rowHeight: CGFloat = 27
    static let rowGap: CGFloat = 2
    static var rowStep: CGFloat { rowHeight + rowGap }
    static let headingHeight: CGFloat = 22
    /// 子面板标题区：上边距 7 + 标题 13 + 间距 3 + 底边 5。
    static let subChrome: CGFloat = 28
    static let listMaxHeight: CGFloat = 377
    static let font: CGFloat = 12
    static let smallFont: CGFloat = 10.5
    static let iconColumn: CGFloat = 15
    static let valueMaxWidth: CGFloat = 112
    static let switchSize = CGSize(width: 32, height: 19)
    static let knob: CGFloat = 15
}
