import AppKit
import CoreGraphics
import Foundation

// kongshan 应用图标：深蓝→靛紫渐变 squircle + 白色盾牌 + 盾内三点连线（分流意象）。
// macOS 图标自带形状，不由系统裁剪，因此这里自己画圆角方并留出标准留白。

func drawIcon(size: CGFloat, context: CGContext) {
    let s = size
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // 标准 macOS 图标：内容占画布约 82%，四周留白
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237 // Big Sur squircle 近似圆角比例

    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 投影
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -s * 0.012),
        blur: s * 0.03,
        color: NSColor.black.withAlphaComponent(0.28).cgColor
    )
    context.addPath(squircle)
    context.setFillColor(NSColor.white.cgColor)
    context.fillPath()
    context.restoreGState()

    // 渐变底
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let colors = [
        NSColor(srgbRed: 0.30, green: 0.53, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.24, green: 0.33, blue: 0.90, alpha: 1).cgColor,
        NSColor(srgbRed: 0.36, green: 0.22, blue: 0.78, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors,
        locations: [0, 0.55, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    // 顶部高光
    let glossColors = [
        NSColor.white.withAlphaComponent(0.22).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    let gloss = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: glossColors,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gloss,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY),
        options: []
    )
    context.restoreGState()

    // 盾牌：以 rect 中心为基准的参数化路径
    let cx = rect.midX
    let shieldW = rect.width * 0.50
    let shieldH = rect.height * 0.58
    let top = rect.midY + shieldH * 0.50
    let bottom = rect.midY - shieldH * 0.50
    let halfW = shieldW / 2

    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: cx, y: top))
    shield.addLine(to: CGPoint(x: cx + halfW, y: top - shieldH * 0.24))
    shield.addLine(to: CGPoint(x: cx + halfW, y: bottom + shieldH * 0.30))
    shield.addQuadCurve(
        to: CGPoint(x: cx, y: bottom),
        control: CGPoint(x: cx + halfW * 0.90, y: bottom + shieldH * 0.06)
    )
    shield.addQuadCurve(
        to: CGPoint(x: cx - halfW, y: bottom + shieldH * 0.30),
        control: CGPoint(x: cx - halfW * 0.90, y: bottom + shieldH * 0.06)
    )
    shield.addLine(to: CGPoint(x: cx - halfW, y: top - shieldH * 0.24))
    shield.closeSubpath()

    context.saveGState()
    context.addPath(shield)
    context.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
    context.fillPath()
    context.restoreGState()

    // 盾内分流图形：一个入点分向两个出点
    context.saveGState()
    context.addPath(shield)
    context.clip()

    let nodeR = shieldW * 0.088
    let inPoint = CGPoint(x: cx, y: rect.midY + shieldH * 0.19)
    let outLeft = CGPoint(x: cx - shieldW * 0.235, y: rect.midY - shieldH * 0.16)
    let outRight = CGPoint(x: cx + shieldW * 0.235, y: rect.midY - shieldH * 0.16)

    let ink = NSColor(srgbRed: 0.24, green: 0.33, blue: 0.90, alpha: 1).cgColor
    context.setStrokeColor(ink)
    context.setLineWidth(max(1, shieldW * 0.055))
    context.setLineCap(.round)

    context.move(to: inPoint)
    context.addLine(to: CGPoint(x: cx, y: rect.midY))
    context.strokePath()

    context.move(to: CGPoint(x: cx, y: rect.midY))
    context.addCurve(
        to: outLeft,
        control1: CGPoint(x: cx, y: rect.midY - shieldH * 0.10),
        control2: CGPoint(x: outLeft.x, y: rect.midY - shieldH * 0.06)
    )
    context.strokePath()

    context.move(to: CGPoint(x: cx, y: rect.midY))
    context.addCurve(
        to: outRight,
        control1: CGPoint(x: cx, y: rect.midY - shieldH * 0.10),
        control2: CGPoint(x: outRight.x, y: rect.midY - shieldH * 0.06)
    )
    context.strokePath()

    context.setFillColor(ink)
    for point in [inPoint, outLeft, outRight] {
        context.fillEllipse(in: CGRect(
            x: point.x - nodeR,
            y: point.y - nodeR,
            width: nodeR * 2,
            height: nodeR * 2
        ))
    }
    context.restoreGState()
}

func writePNG(size: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "icon", code: 1)
    }
    drawIcon(size: CGFloat(size), context: context)
    guard let image = context.makeImage() else { throw NSError(domain: "icon", code: 2) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// iconutil 需要的标准命名
let entries: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]
for (size, name) in entries {
    try writePNG(size: size, to: outputDirectory.appending(path: name))
}
print("wrote \(entries.count) png into \(outputDirectory.path)")
