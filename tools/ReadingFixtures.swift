// macOS: swift tools/ReadingFixtures.swift <output-directory>
// 原创几何封面与测试页，仅供模拟器 smoke test，不包含真实漫画或账号。
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let titles = ["月海来信", "星际漫游", "雨夜档案", "时间之外", "失重日记", "银河回声"]
let colors: [NSColor] = [
  NSColor(srgbRed: 0.14, green: 0.3, blue: 0.38, alpha: 1),
  NSColor(srgbRed: 0.24, green: 0.22, blue: 0.41, alpha: 1),
  NSColor(srgbRed: 0.13, green: 0.33, blue: 0.3, alpha: 1),
  NSColor(srgbRed: 0.39, green: 0.29, blue: 0.29, alpha: 1)
]
func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor) {
  (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
    .font: NSFont.systemFont(ofSize: size, weight: .light), .foregroundColor: color
  ])
}
func page(title: String, index: Int, color: NSColor, destination: URL) throws {
  let image = NSImage(size: NSSize(width: 600, height: 800))
  image.lockFocus()
  if index == 0 {
    color.setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill()
    NSColor.white.withAlphaComponent(0.15).setStroke()
    for offset in [0, 60, 140] {
      let orbit = NSBezierPath(ovalIn: NSRect(x: 140-offset, y: 220-offset, width: 550, height: 550))
      orbit.lineWidth = 1.5; orbit.stroke()
    }
    text("Y / D     ORIGINAL TEST FIXTURE", x: 48, y: 730, size: 15, color: .white.withAlphaComponent(0.55))
    text(String(title.prefix(1)), x: 135, y: 300, size: 230, color: .white.withAlphaComponent(0.25))
    text(title, x: 48, y: 140, size: 48, color: .white)
    text("ORBITAL · 几何测试封面", x: 48, y: 92, size: 18, color: .white.withAlphaComponent(0.6))
  } else {
    NSColor(white: 0.95, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 600, height: 800).fill()
    for (i, rect) in [NSRect(x: 24, y: 420, width: 552, height: 340), NSRect(x: 24, y: 40, width: 270, height: 360), NSRect(x: 310, y: 40, width: 266, height: 360)].enumerated() {
      NSColor(white: i == 0 ? 0.64 : 0.84, alpha: 1).setFill(); rect.fill()
      NSColor.darkGray.setStroke(); NSBezierPath(rect: rect).stroke()
      for building in 0..<9 {
        let height = CGFloat(60 + ((building * 37 + index * 19) % 160))
        NSColor(white: 0.18, alpha: 1).setFill()
        NSRect(x: rect.minX + CGFloat(building) * rect.width / 9, y: rect.minY, width: rect.width / 11, height: height).fill()
      }
    }
    NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 390, y: 620, width: 90, height: 90)).fill()
    text(title, x: 48, y: 690, size: 28, color: .white)
    text("城市的另一侧，是故事的起点。", x: 45, y: 450, size: 22, color: .white)
    text("测试页 \(index + 1) / 8", x: 220, y: 12, size: 13, color: .darkGray)
  }
  image.unlockFocus()
  let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
  try representation.representation(using: .png, properties: [:])!.write(to: destination)
}
for (series, title) in titles.enumerated() {
  for chapter in 1...(series == 0 ? 4 : 2) {
    let folder = root.appendingPathComponent(title).appendingPathComponent(String(format: "第1卷 第%02d话", chapter))
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for index in 0..<8 {
      try page(title: title, index: index, color: colors[series % colors.count], destination: folder.appendingPathComponent(String(format: "%03d.png", index + 1)))
    }
  }
}
print("Created six local reading fixtures")
