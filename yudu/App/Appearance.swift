import SwiftUI

// MARK: - 外观

enum AppearanceMode: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }
  var label: String {
    switch self {
    case .system: "跟随系统"
    case .light: "浅色"
    case .dark: "深色"
    }
  }

  var scheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

// MARK: - 护眼

/// 护眼设置（UserDefaults 持久化，阅读器内叠加滤镜）
struct EyeCare: Equatable, Codable {
  /// 护眼总开关：默认关闭，漫画保持原色
  var enabled = false
  /// 亮度 0.4...1.0（低于 1 变暗）
  var brightness: Double = 1.0
  /// 暖色 0...0.6
  var warmth: Double = 0.35
  var scheduleEnabled = false

  static let storageKey = "eyeCare"

  init() {}

  private enum CodingKeys: String, CodingKey {
    case enabled, brightness, warmth, scheduleEnabled
  }

  /// 兼容旧版本存储（没有 enabled 字段时按关闭处理）。
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    brightness = try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 1.0
    warmth = try container.decodeIfPresent(Double.self, forKey: .warmth) ?? 0.35
    scheduleEnabled = try container.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? false
  }

  static func load(_ defaults: UserDefaults = .standard) -> EyeCare {
    guard let data = defaults.data(forKey: storageKey),
          let value = try? JSONDecoder().decode(EyeCare.self, from: data) else {
      return EyeCare()
    }
    return value
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }

  /// 20:00 – 次日 07:00 暖色生效
  static func inWarmSchedule(now: Date = .now, calendar: Calendar = .current) -> Bool {
    let hour = calendar.component(.hour, from: now)
    return hour >= 20 || hour < 7
  }

  /// 总开关关闭时不叠加任何滤镜。
  var effectiveBrightness: Double {
    enabled ? brightness : 1.0
  }

  /// 当前生效的暖色值
  var effectiveWarmth: Double {
    guard enabled else { return 0 }
    if scheduleEnabled, !Self.inWarmSchedule() { return 0 }
    return warmth
  }

  var isIdentity: Bool { effectiveBrightness >= 1.0 && effectiveWarmth <= 0.001 }
}
