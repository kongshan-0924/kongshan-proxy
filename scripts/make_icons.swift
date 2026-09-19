#!/usr/bin/env swift
//
// 生成 App 图标（Resources/AppIcon.icns）。
//
// 为什么用绘制脚本而不是提交一堆 PNG：图标是**可重生成的产物**。形状、配色、留白都在这里，
// 改一个数字重跑即可，不用在十个尺寸之间手工对齐；也避免二进制图片进 git 后无法 diff。
//
// 设计取意「空山不见人」：深蓝底 + 白色山形剪影 + 山脚一层薄雾（那个「空」）。
// 用法：swift scripts/make_icons.swift  然后 iconutil 打包（见 make_icons.sh）。

import AppKit
import Foundation

// MARK: - 形状

/// macOS 应用图标的圆角矩形是**超椭圆**（continuous corner），不是普通圆角矩形。
/// 用普通圆角在大尺寸下肉眼可见地"方"，与系统其它图标摆在一起会显得格格不入。
func squirclePath(in rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        // |x/a|^n + |y/b|^n = 1 的参数化形式
        let x = cx + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 山脊。坐标按 0~1 归一化（y 向上），方便按尺寸缩放。
///
/// 前后两道山脊 + 中间一层薄雾。三个理由：
/// 1. 「空山」的重点是**空**——天空必须占大头，山只压在下缘约四成，
///    之前山填了六成画布，远看就是个白色色块，认不出是山。
/// 2. 后脊半透明、前脊实心，拉出纵深；单层剪影在大尺寸下很平。
/// 3. 16px 下只有前脊的轮廓还能被辨认，所以前脊的两峰一谷刻意做得夸张、
///    峰谷落差大，缩到菜单栏尺寸也不会糊成一条直线。
let backRidge: [CGPoint] = [
    CGPoint(x: -0.02, y: 0.26),
    CGPoint(x: 0.22, y: 0.52),
    CGPoint(x: 0.40, y: 0.34),
    CGPoint(x: 0.66, y: 0.58),
    CGPoint(x: 1.02, y: 0.24)
]

let frontRidge: [CGPoint] = [
    CGPoint(x: -0.02, y: 0.16),
    CGPoint(x: 0.34, y: 0.46),
    CGPoint(x: 0.52, y: 0.29),
    CGPoint(x: 0.68, y: 0.38),
    CGPoint(x: 1.02, y: 0.14)
]

func drawIcon(size: CGFloat, into context: CGContext) {
    context.saveGState()

    // 图标网格：圆角矩形占画布约 80%，四周留透明边。系统会在这层留白里加投影。
    let inset = size * 0.098
    let plate = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squirclePath(in: plate)

    context.addPath(shape)
    context.clip()

    // 天空：自上而下由浅到深。上浅下深符合光从上来的直觉。
    let sky = [
        CGColor(red: 0.29, green: 0.62, blue: 0.96, alpha: 1),
        CGColor(red: 0.07, green: 0.31, blue: 0.72, alpha: 1)
    ]
    if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: sky as CFArray,
        locations: [0, 1]
    ) {
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: plate.midX, y: plate.maxY),
            end: CGPoint(x: plate.midX, y: plate.minY),
            options: []
        )
    }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: plate.minX + p.x * plate.width, y: plate.minY + p.y * plate.height)
    }

    func ridgePath(_ ridge: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: point(ridge[0]))
        for p in ridge.dropFirst() { path.addLine(to: point(p)) }
        path.addLine(to: CGPoint(x: plate.maxX, y: plate.minY))
        path.addLine(to: CGPoint(x: plate.minX, y: plate.minY))
        path.closeSubpath()
        return path
    }

    // 后脊：半透明，只负责纵深，不抢轮廓。
    context.addPath(ridgePath(backRidge))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.34))
    context.fillPath()

    // 薄雾：压在两道山脊之间的一条窄带。这是「空」——山腰断开一层，
    // 后脊像浮在雾上。带子必须画在前脊**之前**，否则会盖住前脊的轮廓。
    let mist = CGRect(
        x: plate.minX,
        y: plate.minY + plate.height * 0.245,
        width: plate.width,
        height: plate.height * 0.052
    )
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.40))
    context.fill(mist)

    // 前脊：实心白，是缩到 16px 后唯一还认得出的部分。
    context.addPath(ridgePath(frontRidge))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
    context.fillPath()

    context.restoreGState()
}

// MARK: - 输出

func writePNG(size: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "icon", code: 2)
    }
    NSGraphicsContext.current = graphicsContext
    let context = graphicsContext.cgContext
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setAllowsAntialiasing(true)
    drawIcon(size: CGFloat(size), into: context)
    graphicsContext.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 3)
    }
    try data.write(to: url)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "dist/AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// iconutil 要求的全套文件名。
let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1_024)
]
for variant in variants {
    try writePNG(size: variant.size, to: outputDirectory.appending(path: "\(variant.name).png"))
}
FileHandle.standardError.write(Data("已生成 \(variants.count) 个尺寸到 \(outputDirectory.path)\n".utf8))
