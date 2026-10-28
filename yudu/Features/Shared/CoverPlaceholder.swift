import SwiftUI

// MARK: - 程序化轨道封面
struct CoverPalette {
  let top: Color
  let bottom: Color

  static let all: [CoverPalette] = [
    .init(top: .hex(0x234C61), bottom: .hex(0x0B1B30)),
    .init(top: .hex(0x3D3868), bottom: .hex(0x17172E)),
    .init(top: .hex(0x22544E), bottom: .hex(0x0A2428)),
    .init(top: .hex(0x644A49), bottom: .hex(0x291D30)),
    .init(top: .hex(0x304E77), bottom: .hex(0x101B35)),
    .init(top: .hex(0x514067), bottom: .hex(0x241B32)),
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

/// 无真实封面时的回退，不覆盖漫画本身的美术。
struct PlaceholderCoverView: View {
  let title: String
  let key: String
  private var palette: CoverPalette { CoverPalette.palette(for: key) }

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        LinearGradient(colors: [palette.top, palette.bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
        Circle().stroke(.white.opacity(0.16), lineWidth: 0.7)
          .frame(width: geometry.size.width * 1.25, height: geometry.size.width * 1.25)
          .offset(x: geometry.size.width * 0.18, y: geometry.size.height * 0.1)
        Circle().stroke(.white.opacity(0.08), lineWidth: 0.7)
          .padding(geometry.size.width * 0.22)
        Text(String(title.first ?? "雨"))
          .font(.system(size: geometry.size.width * 0.65, weight: .ultraLight, design: .serif))
          .foregroundStyle(.white.opacity(0.3))
          .offset(y: -geometry.size.height * 0.03)
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Y / D").font(.system(size: 8, design: .monospaced)).tracking(2)
            Spacer()
            Image(systemName: "sparkle").font(.system(size: 9))
          }.foregroundStyle(.white.opacity(0.5))
          Spacer()
          Text(title).font(.system(size: max(11, geometry.size.width * 0.1), weight: .medium))
            .foregroundStyle(.white.opacity(0.95)).lineLimit(2)
          Rectangle().fill(.white.opacity(0.35)).frame(width: 22, height: 1)
        }.padding(geometry.size.width * 0.12)
      }.clipped()
    }.accessibilityHidden(true)
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
      image = nil
      for _ in 0..<24 {
        guard !Task.isCancelled else { return }
        if let loaded = UIImage(contentsOfFile: CoverStore.shared.coverURL(seriesKey: seriesKey).path) {
          image = loaded
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}
