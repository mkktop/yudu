import SwiftUI

/// Orbital：所有导航页面共用的语义色与组件。浅色模式保留相同层级，阅读画面独立控制。
enum YuduTheme {
  static let background = adaptive(0x080E18, 0xF1F5F8)
  static let surface = adaptive(0x111D2C, 0xFFFFFF)
  static let elevated = adaptive(0x19283A, 0xE6EEF4)
  static let accent = adaptive(0x74E6DB, 0x006D68)
  static let violet = adaptive(0xB4A1F5, 0x6A4DB3)
  static let text = adaptive(0xEAF3FC, 0x142333)
  static let muted = adaptive(0x91A6BC, 0x52667B)
  static let line = adaptive(0x2A3D50, 0xCAD7E2)
  static let success = adaptive(0x92DBB3, 0x24734B)
  static let warning = adaptive(0xF2C38A, 0x925500)

  private static func adaptive(_ dark: UInt32, _ light: UInt32) -> Color {
    Color(uiColor: UIColor { traits in
      let value = traits.userInterfaceStyle == .dark ? dark : light
      return UIColor(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: 1
      )
    })
  }
}

struct OrbitalBackground: View {
  var body: some View {
    ZStack(alignment: .topTrailing) {
      YuduTheme.background
      Circle()
        .fill(YuduTheme.accent.opacity(0.045))
        .frame(width: 340, height: 340)
        .blur(radius: 60)
        .offset(x: 150, y: -160)
      Canvas { context, size in
        var grid = Path()
        stride(from: CGFloat(0), to: size.width, by: 32).forEach { x in
          grid.move(to: CGPoint(x: x, y: 0))
          grid.addLine(to: CGPoint(x: x, y: min(size.height, 280)))
        }
        stride(from: CGFloat(0), to: min(size.height, 280), by: 32).forEach { y in
          grid.move(to: CGPoint(x: 0, y: y))
          grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(YuduTheme.line.opacity(0.16)), lineWidth: 0.5)
      }
      .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct PanelModifier: ViewModifier {
  var accent: Color?
  func body(content: Content) -> some View {
    content
      .background(YuduTheme.surface, in: RoundedRectangle(cornerRadius: 22))
      .overlay {
        RoundedRectangle(cornerRadius: 22)
          .strokeBorder((accent ?? YuduTheme.line).opacity(accent == nil ? 0.65 : 0.4), lineWidth: 1)
          .allowsHitTesting(false)
      }
  }
}

extension View {
  func yuduPanel(accent: Color? = nil) -> some View { modifier(PanelModifier(accent: accent)) }
  func yuduPage() -> some View {
    self
      .scrollContentBackground(.hidden)
      .background { OrbitalBackground() }
      .foregroundStyle(YuduTheme.text)
      .toolbarBackground(YuduTheme.background, for: .navigationBar)
  }
}

struct OrbitalEmblem: View {
  var size: CGFloat = 44
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.28)
        .fill(YuduTheme.accent.opacity(0.1))
      Circle()
        .trim(from: 0.08, to: 0.86)
        .stroke(YuduTheme.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        .rotationEffect(.degrees(-40))
        .padding(size * 0.13)
      Image(systemName: "book.closed.fill")
        .font(.system(size: size * 0.33, weight: .light))
        .foregroundStyle(YuduTheme.accent)
      Circle()
        .fill(YuduTheme.accent)
        .frame(width: size * 0.09, height: size * 0.09)
        .offset(x: size * 0.29, y: -size * 0.24)
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct YuduWordmark: View {
  var body: some View {
    HStack(spacing: 10) {
      OrbitalEmblem(size: 34)
      Text("雨读")
        .font(.system(.headline, design: .rounded))
        .foregroundStyle(YuduTheme.text)
      Text("YUDU")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .tracking(2)
        .foregroundStyle(YuduTheme.muted)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("雨读 Yudu")
  }
}

struct SectionHeading: View {
  let title: String
  var eyebrow: String = ""
  var detail: String = ""
  var body: some View {
    HStack(alignment: .bottom) {
      VStack(alignment: .leading, spacing: 5) {
        if !eyebrow.isEmpty {
          Text(eyebrow)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .tracking(2)
            .foregroundStyle(YuduTheme.accent)
        }
        Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
      }
      Spacer(minLength: 8)
      if !detail.isEmpty {
        Text(detail).font(.caption.monospacedDigit()).foregroundStyle(YuduTheme.muted)
      }
    }
    .foregroundStyle(YuduTheme.text)
  }
}

struct StatusPill: View {
  let text: String
  var color: Color = YuduTheme.accent
  var icon: String? = nil
  var body: some View {
    HStack(spacing: 5) {
      if let icon { Image(systemName: icon) }
      Text(text)
    }
    .font(.caption2.weight(.medium))
    .foregroundStyle(color)
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(color.opacity(0.1), in: Capsule())
    .overlay { Capsule().strokeBorder(color.opacity(0.2), lineWidth: 0.5) }
  }
}

struct OrbitalButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var prominent = true
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 50)
      .foregroundStyle(prominent ? YuduTheme.background : YuduTheme.accent)
      .background(prominent ? YuduTheme.accent : YuduTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
      .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
      .contentShape(RoundedRectangle(cornerRadius: 15))
  }
}

struct NoticeView: View {
  let title: String
  var message: String = ""
  var icon: String = "info.circle"
  var color: Color = YuduTheme.accent
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).foregroundStyle(color).padding(.top, 2)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(color)
        if !message.isEmpty {
          Text(message).font(.caption).foregroundStyle(YuduTheme.muted)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .yuduPanel(accent: color)
  }
}

extension LibraryEntity {
  var sourceLabel: String {
    switch kind {
    case "folder": "文件夹"
    case "webdav": "WebDAV"
    case "cloud189": remoteFamilyId == nil ? "天翼个人云" : "天翼家庭云"
    default: "本机文件"
    }
  }
  var sourceIcon: String {
    switch kind {
    case "folder": "folder"
    case "webdav": "externaldrive.connected.to.line.below"
    case "cloud189": "cloud"
    default: "internaldrive"
    }
  }
}

extension Queries.ShelfStatus {
  var label: String {
    switch self {
    case .unread: "未读"
    case .reading: "在读"
    case .finished: "已读完"
    }
  }
  var color: Color {
    switch self {
    case .unread: YuduTheme.muted
    case .reading: YuduTheme.accent
    case .finished: YuduTheme.success
    }
  }
}
