import SwiftUI

// MARK: - 程序化书脊封面
//
// 没有可生成封面的章节时，用书名 + key 哈希出一本"书"：
// 布面配色渐变 + 宋体大水印字 + 右上竖排书名，视觉上像一册线装书。

struct CoverPalette {
  let top: Color
  let bottom: Color

  static let all: [CoverPalette] = [
    .init(top: .hex(0x3D5A73), bottom: .hex(0x24384A)), // 黛蓝
    .init(top: .hex(0x4A6B57), bottom: .hex(0x2C4033)), // 松绿
    .init(top: .hex(0x6D4A6E), bottom: .hex(0x432C44)), // 绛紫
    .init(top: .hex(0x96543A), bottom: .hex(0x5E3222)), // 赭石
    .init(top: .hex(0x3E6B6B), bottom: .hex(0x24403F)), // 黛青
    .init(top: .hex(0x7E3B47), bottom: .hex(0x4A2029)), // 酒红
    .init(top: .hex(0x5A6B7E), bottom: .hex(0x37424F)), // 灰蓝
    .init(top: .hex(0x7A6248), bottom: .hex(0x4A3A29)), // 茶褐
  ]

  /// key 稳定哈希（djb2）取色，同一本书永远同色
  static func palette(for key: String) -> CoverPalette {
    var hash: UInt64 = 5381
    for byte in key.utf8 {
      hash = (hash &* 33) &+ UInt64(byte)
    }
    return all[Int(hash % UInt64(all.count))]
  }
}

extension Color {
  static func hex(_ value: UInt32) -> Color { Color(hex: value) }

  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}

/// 占位封面：竖排书名 + 水印首字
struct PlaceholderCoverView: View {
  let title: String
  let key: String

  private var palette: CoverPalette { CoverPalette.palette(for: key) }
  private var watermark: String { String(title.first ?? "书") }
  private var spineChars: [Character] { Array(title.prefix(7).dropFirst()) }

  var body: some View {
    ZStack {
      LinearGradient(colors: [palette.top, palette.bottom], startPoint: .top, endPoint: .bottom)

      Text(watermark)
        .font(.custom("Songti SC", size: 150).weight(.bold))
        .foregroundStyle(.white.opacity(0.15))
        .offset(y: 8)

      VStack(spacing: 5) {
        Rectangle()
          .fill(.white.opacity(0.6))
          .frame(width: 1.5, height: 12)
        ForEach(Array(spineChars.enumerated()), id: \.offset) { _, char in
          Text(String(char))
            .font(.custom("Songti SC", size: 15).weight(.semibold))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      .padding(.trailing, 9)
      .padding(.top, 10)
    }
  }
}

// MARK: - 封面图（磁盘缓存 + 生成中重试 + 占位回退）

struct CoverImage: View {
  let seriesKey: String
  var title: String = ""
  @Environment(LibraryService.self) private var libraryService
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        PlaceholderCoverView(title: title, key: seriesKey)
      }
    }
    .task(id: "\(seriesKey)#\(libraryService.coverVersion)") {
      // 封面可能在扫描后几秒内生成，带重试
      for _ in 0..<24 {
        if let loaded = UIImage(contentsOfFile: CoverStore.shared.coverURL(seriesKey: seriesKey).path) {
          image = loaded
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}
