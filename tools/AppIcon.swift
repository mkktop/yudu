// 雨读 App 图标生成脚本：swift tools/AppIcon.swift <输出目录> → AppIcon1024.png
// 生成后替换 yudu/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation

// 雨读 App 图标：朱砂渐变底 + 雨滴 + 摊开的书
let S: CGFloat = 1024
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

let bgColors = [CGColor(red: 0.79, green: 0.33, blue: 0.24, alpha: 1),
                CGColor(red: 0.42, green: 0.12, blue: 0.07, alpha: 1)] as CFArray
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: bgColors, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S), end: CGPoint(x: S/2, y: 0), options: [])

// 微妙的对角光晕
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: 0, width: S, height: S))
let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                      colors: [CGColor(red: 1, green: 0.9, blue: 0.75, alpha: 0.22), CGColor(red: 1, green: 0.9, blue: 0.75, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 260, y: 820), startRadius: 0,
                       endCenter: CGPoint(x: 260, y: 820), endRadius: 700, options: [])
ctx.restoreGState()

func drop(_ c: CGContext, at p: CGPoint, scale r: CGFloat) {
  let path = CGMutablePath()
  path.move(to: CGPoint(x: p.x, y: p.y + 1.55 * r))
  path.addCurve(to: CGPoint(x: p.x - r, y: p.y - 0.15 * r),
                control1: CGPoint(x: p.x - 0.62 * r, y: p.y + 0.62 * r),
                control2: CGPoint(x: p.x - r, y: p.y + 0.18 * r))
  path.addArc(center: CGPoint(x: p.x, y: p.y - 0.15 * r), radius: r,
              startAngle: .pi, endAngle: 0, clockwise: false)
  path.addCurve(to: CGPoint(x: p.x, y: p.y + 1.55 * r),
                control1: CGPoint(x: p.x + r, y: p.y + 0.18 * r),
                control2: CGPoint(x: p.x + 0.62 * r, y: p.y + 0.62 * r))
  path.closeSubpath()
  c.addPath(path)
  c.setFillColor(CGColor(red: 0.965, green: 0.93, blue: 0.87, alpha: 0.96))
  c.fillPath()
}

drop(ctx, at: CGPoint(x: 300, y: 640), scale: 48)
drop(ctx, at: CGPoint(x: 512, y: 770), scale: 62)
drop(ctx, at: CGPoint(x: 724, y: 648), scale: 44)

// 摊开的书：书脊下凹、外角上翘
let paper = CGColor(red: 0.985, green: 0.965, blue: 0.925, alpha: 1)
let spineX: CGFloat = 512
let spineTopY: CGFloat = 290
let outerTopY: CGFloat = 382
let spineBotY: CGFloat = 148
let outerBotY: CGFloat = 192
let halfW: CGFloat = 320

// 书下投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40,
              color: CGColor(red: 0.1, green: 0.02, blue: 0.0, alpha: 0.45))

func page(_ c: CGContext, side: CGFloat) {
  func px(_ f: CGFloat) -> CGFloat { spineX + side * f * halfW }
  let path = CGMutablePath()
  path.move(to: CGPoint(x: spineX, y: spineTopY))
  path.addQuadCurve(to: CGPoint(x: px(1.0), y: outerTopY),
                    control: CGPoint(x: px(0.45), y: spineTopY + 40))
  path.addLine(to: CGPoint(x: px(1.0), y: outerBotY))
  path.addQuadCurve(to: CGPoint(x: spineX, y: spineBotY),
                    control: CGPoint(x: px(0.45), y: spineBotY + 44))
  path.closeSubpath()
  c.addPath(path)
  c.setFillColor(paper)
  c.fillPath()

  // 页面上的文字线（内端低、外端高，随页弧度）
  c.saveGState()
  c.addPath(path)
  c.clip()
  c.setStrokeColor(CGColor(red: 0.72, green: 0.26, blue: 0.18, alpha: 0.28))
  c.setLineWidth(13)
  c.setLineCap(.round)
  for i in 0..<3 {
    let ly = 330 - CGFloat(i) * 58
    c.beginPath()
    c.move(to: CGPoint(x: px(0.52), y: ly - 40))
    c.addQuadCurve(to: CGPoint(x: px(0.90), y: ly),
                   control: CGPoint(x: px(0.71), y: ly - 26))
    c.strokePath()
  }
  c.restoreGState()
}

page(ctx, side: 1)
page(ctx, side: -1)
ctx.restoreGState()

// 中缝阴影
let seam = CGMutablePath()
seam.move(to: CGPoint(x: spineX, y: spineTopY))
seam.addQuadCurve(to: CGPoint(x: spineX, y: spineBotY), control: CGPoint(x: spineX + 14, y: (spineTopY + spineBotY) / 2))
seam.addQuadCurve(to: CGPoint(x: spineX, y: spineTopY), control: CGPoint(x: spineX - 14, y: (spineTopY + spineBotY) / 2))
seam.closeSubpath()
ctx.addPath(seam)
ctx.setFillColor(CGColor(red: 0.35, green: 0.10, blue: 0.06, alpha: 0.45))
ctx.fillPath()

let img = ctx.makeImage()!
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/yudu-icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let out = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon1024.png")
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("written \(out.path)")
