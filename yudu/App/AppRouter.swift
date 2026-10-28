import SwiftUI
import Observation

enum AppTab: Hashable {
  case bookshelf
  case library
  case stats
  case settings
}

/// 全局导航状态（Tab + 各 Tab 的导航栈）
@MainActor
@Observable
final class AppRouter {
  var tab: AppTab = .bookshelf
  var showImport = false
  var bookshelfPath: [BookshelfRoute] = []
  var statsPath: [StatsRoute] = []
  var settingsPath: [SettingsRoute] = []
}

enum BookshelfRoute: Hashable {
  case series(SeriesEntity)
  /// token 保证每次进入阅读器都是新的视图身份（避免快速退出重进时复用旧状态）
  case reader(series: SeriesEntity, startChapter: ChapterEntity?, token: UUID)

  static func reader(series: SeriesEntity, startChapter: ChapterEntity?) -> BookshelfRoute {
    .reader(series: series, startChapter: startChapter, token: UUID())
  }
}

enum StatsRoute: Hashable {}

enum SettingsRoute: Hashable {}
