import Foundation
import SwiftData

/// 一个书库：授权的文件夹（原地扫描）或导入文件库（拷贝进沙盒）或 WebDAV
@Model
final class LibraryEntity {
  @Attribute(.unique) var key: String
  var name: String
  /// "folder"（授权文件夹）| "imports"（导入文件）| "webdav"（key 为 "webdav:<挂载地址>"）
  var kind: String
  /// folder 库的安全作用域书签
  var bookmark: Data?
  /// webdav 库的登录名（密码在 Keychain）；cloud189 库存登录昵称
  var username: String?
  /// cloud189 库：挂载目录 id 与家庭云 id（nil = 个人云）
  var remoteFolderId: String?
  var remoteFamilyId: String?
  var createdAt: Date

  @Relationship(deleteRule: .cascade, inverse: \SeriesEntity.library)
  var series: [SeriesEntity] = []

  init(key: String, name: String, kind: String, bookmark: Data? = nil, createdAt: Date = Date.now) {
    self.key = key
    self.name = name
    self.kind = kind
    self.bookmark = bookmark
    self.createdAt = createdAt
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
