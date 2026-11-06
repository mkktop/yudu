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
  var libraryPath: [LibraryRoute] = []
  var statsPath: [StatsRoute] = []
  var settingsPath: [SettingsRoute] = []
}

enum BookshelfRoute: Hashable {
  case series(SeriesEntity)
  /// token 保证每次进入阅读器都是新的视图身份（避免快速退出重进时复用旧状态）
  case reader(series: SeriesEntity, startChapter: ChapterEntity?, token: UUID)
}

extension AppRouter {
  /// 进阅读器统一走这里：在点击时生成 token，而不是在 body 求值时生成，
  /// 否则每次刷新都会改变 NavigationLink 的值。
  func openReader(series: SeriesEntity, startChapter: ChapterEntity?) {
    bookshelfPath.append(.reader(series: series, startChapter: startChapter, token: UUID()))
  }
}

/// 网盘浏览器试读会话（纯值，可在导航栈中携带；目标页据此解析客户端）
struct PreviewChapterItem: Hashable {
  var path: String
  var kind: String
  var title: String
  var size: Int64
  var modifiedAt: Date
}

struct PreviewPayload: Hashable {
  /// SourceEntity.key，目的地据此取客户端
  var sourceKey: String
  /// "webdav" | "cloud189"
  var sourceKind: String
  /// 顶栏展示的系列名（所在文件夹名）
  var folderTitle: String
  var items: [PreviewChapterItem]
  var index: Int
}

enum LibraryRoute: Hashable {
  case browser(source: SourceEntity)
  /// 管理某个来源（账号）已导入的书库；nil = 本机书库
  case sourceManage(source: SourceEntity?)
  /// token 语义同 BookshelfRoute.reader
  case previewReader(PreviewPayload, token: UUID)
}

extension AppRouter {
  func openCloudBrowser(source: SourceEntity) {
    libraryPath.append(.browser(source: source))
  }

  func openSourceManage(source: SourceEntity?) {
    libraryPath.append(.sourceManage(source: source))
  }

  func openPreviewReader(_ payload: PreviewPayload) {
    libraryPath.append(.previewReader(payload, token: UUID()))
  }
}

enum StatsRoute: Hashable {}

enum SettingsRoute: Hashable {}
