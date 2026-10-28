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
  /// 亮度 0.4...1.0（低于 1 变暗）
  var brightness: Double = 1.0
  /// 暖色 0...0.6
  var warmth: Double = 0.35
  var scheduleEnabled = false

  static let storageKey = "eyeCare"

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

  /// 当前生效的暖色值
  var effectiveWarmth: Double {
    if scheduleEnabled, !Self.inWarmSchedule() { return 0 }
    return warmth
  }

  var isIdentity: Bool { brightness >= 1.0 && effectiveWarmth <= 0.001 }
}
