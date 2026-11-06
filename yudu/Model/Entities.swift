import Foundation
import SwiftData

/// 一个网盘账号（WebDAV / 天翼云盘）。同一种网盘可添加任意多个账号，
/// 凭据（WebDAV 密码 / 天翼会话）按账号隔离存放在 Keychain。
@Model
final class SourceEntity {
  @Attribute(.unique) var key: String
  /// "webdav" | "cloud189"
  var kind: String
  var name: String
  /// webdav 账号的服务器地址
  var baseURL: String?
  /// webdav 登录名 / 天翼登录昵称
  var username: String?
  var createdAt: Date

  @Relationship(deleteRule: .cascade, inverse: \LibraryEntity.source)
  var libraries: [LibraryEntity] = []

  init(key: String, name: String, kind: String, baseURL: String? = nil, username: String? = nil, createdAt: Date = Date.now) {
    self.key = key
    self.kind = kind
    self.name = name
    self.baseURL = baseURL
    self.username = username
    self.createdAt = createdAt
  }

  /// Keychain 槽：WebDAV 密码
  var passwordAccount: String { "yudu-src:\(key)" }
  /// Keychain 槽：天翼会话（JSON）
  var sessionAccount: String { "yudu-src:\(key):session" }
}

/// 一个书库：授权的文件夹（原地扫描）或导入文件库（拷贝进沙盒）或网盘挂载的文件夹。
/// 云端库只是「账号 + 远端目录」的引用；key 格式保持历史不变（seriesKey/缓存/封面都嵌着它）。
@Model
final class LibraryEntity {
  @Attribute(.unique) var key: String
  var name: String
  /// "folder"（授权文件夹）| "imports"（导入文件）| "webdav"（key 为 "webdav:<挂载地址>"）| "cloud189"（key 为 "cloud189:<scope>/<目录id>"）
  var kind: String
  /// folder 库的安全作用域书签
  var bookmark: Data?
  /// webdav 库的登录名（密码在 Keychain）；cloud189 库存登录昵称
  var username: String?
  /// cloud189 库：挂载目录 id 与家庭云 id（nil = 个人云）
  var remoteFolderId: String?
  var remoteFamilyId: String?
  /// 目录结构（用户在导入时选择，可改）：nil = multi（每个子文件夹一部漫画）；"single" = 整库一部漫画
  var layout: String?
  var createdAt: Date
  /// 所属网盘账号（本地库为 nil）
  var source: SourceEntity?

  @Relationship(deleteRule: .cascade, inverse: \SeriesEntity.library)
  var series: [SeriesEntity] = []

  init(key: String, name: String, kind: String, bookmark: Data? = nil, createdAt: Date = Date.now) {
    self.key = key
    self.name = name
    self.kind = kind
    self.bookmark = bookmark
    self.createdAt = createdAt
  }

  var scanLayout: LibraryScanLayout {
    get { LibraryScanLayout(rawValue: layout ?? "") ?? .multi }
    set { layout = newValue == .multi ? nil : newValue.rawValue }
  }
}

/// 一个系列（一部漫画）
@Model
final class SeriesEntity {
  @Attribute(.unique) var key: String
  var title: String
  var addedAt: Date
  var lastReadAt: Date?

  var library: LibraryEntity?
  @Relationship(deleteRule: .cascade, inverse: \ChapterEntity.series)
  var chapters: [ChapterEntity] = []

  init(key: String, title: String, addedAt: Date = Date.now) {
    self.key = key
    self.title = title
    self.addedAt = addedAt
  }
}

/// 一话：压缩包 / 散图文件夹 / PDF
@Model
final class ChapterEntity {
  @Attribute(.unique) var path: String
  var title: String
  var volume: String?
  var number: Double?
  var sortIndex: Int = 0
  /// "folder" | "zip" | "pdf"
  var kind: String = "folder"
  var pageCount: Int = 0
  var fileSize: Int64 = 0
  var modifiedAt: Date = Date.distantPast

  var series: SeriesEntity?
  @Relationship(deleteRule: .cascade, inverse: \ProgressEntity.chapter)
  var progress: ProgressEntity?

  init(path: String, title: String) {
    self.path = path
    self.title = title
  }
}

/// 阅读进度（一话一条）
@Model
final class ProgressEntity {
  var page: Int = 0
  var completed: Bool = false
  var updatedAt: Date = Date.distantPast

  var chapter: ChapterEntity?

  init(page: Int = 0, completed: Bool = false, updatedAt: Date = Date.now) {
    self.page = page
    self.completed = completed
    self.updatedAt = updatedAt
  }
}

/// 阅读统计流水：某天读了多少页（同一天可多条，聚合查询）
@Model
final class ReadingLogEntity {
  var day: String
  var pages: Int
  var at: Date

  init(day: String, pages: Int, at: Date = Date.now) {
    self.day = day
    self.pages = pages
    self.at = at
  }
}
