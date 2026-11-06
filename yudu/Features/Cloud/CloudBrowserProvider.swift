import Foundation

// MARK: - 整盘浏览的统一抽象：一个网盘账号一个 provider
//
// folder/item 的 id 与 LibraryEntity.key、章节 path 遵循同一套规则，
// 所以「已导入」判定和浏览器内试读都能直接复用挂载/阅读链路。

struct CloudBrowserFolder: Hashable, Sendable {
  /// WebDAV：目录 URL 绝对串；天翼：目录 fileId（根为 -11）
  var id: String
  var name: String
  /// 天翼家庭云 id（nil = 个人云或 WebDAV）
  var familyId: String?
}

struct CloudBrowserItem: Identifiable, Hashable, Sendable {
  var id: String
  var name: String
  var isDirectory: Bool
  var size: Int64
  var modifiedAt: Date?
  var isArchive: Bool
  var isPDF: Bool

  var isReadable: Bool { !isDirectory && (isArchive || isPDF) }
}

@MainActor
protocol CloudBrowserProvider: AnyObject {
  /// 顶层入口（WebDAV 单根；天翼为 个人云 + 各家庭云）
  func roots() async -> [CloudBrowserFolder]
  func list(_ folder: CloudBrowserFolder) async throws -> [CloudBrowserItem]
  /// 该文件夹的挂载 key（与 LibraryEntity.key 同规则），用于「已导入」判定
  func mountKey(for folder: CloudBrowserFolder) -> String
  /// 试读章节 path（与 ChapterEntity.path 同规则，可直接驱动 PageSourceFactory）
  func chapterPath(for item: CloudBrowserItem, folder: CloudBrowserFolder) -> String
  /// 试读章节的 kind（"zip" | "pdf" | "folder"）
  func chapterKind(for item: CloudBrowserItem) -> String
}

// MARK: - WebDAV

@MainActor
final class WebDAVBrowserProvider: CloudBrowserProvider {
  private let client: WebDAVClient
  private let rootURL: URL

  init(client: WebDAVClient, rootURL: URL) {
    self.client = client
    self.rootURL = rootURL
  }

  func roots() async -> [CloudBrowserFolder] {
    [CloudBrowserFolder(id: rootURL.absoluteString, name: rootURL.lastPathComponent, familyId: nil)]
  }

  func list(_ folder: CloudBrowserFolder) async throws -> [CloudBrowserItem] {
    guard let url = URL(string: folder.id) else { throw URLError(.badURL) }
    return try await client.list(url).map { item in
      CloudBrowserItem(
        id: item.url.absoluteString, name: item.name, isDirectory: item.isDirectory,
        size: item.contentLength, modifiedAt: item.lastModified,
        isArchive: item.isArchive, isPDF: item.isPDF
      )
    }
  }

  func mountKey(for folder: CloudBrowserFolder) -> String {
    "webdav:" + folder.id
  }

  func chapterPath(for item: CloudBrowserItem, folder: CloudBrowserFolder) -> String {
    item.id
  }

  func chapterKind(for item: CloudBrowserItem) -> String {
    item.isDirectory ? "folder" : (item.isPDF ? "pdf" : "zip")
  }
}

// MARK: - 天翼云盘

@MainActor
final class Cloud189BrowserProvider: CloudBrowserProvider {
  private let client: Cloud189Client
  private var families: [(familyId: String, name: String)] = []

  init(client: Cloud189Client) {
    self.client = client
  }

  func roots() async -> [CloudBrowserFolder] {
    if families.isEmpty {
      families = (try? await client.familyList()) ?? []
    }
    return [CloudBrowserFolder(id: Self.rootFolderId, name: "个人云", familyId: nil)]
      + families.map { CloudBrowserFolder(id: Self.rootFolderId, name: $0.name, familyId: $0.familyId) }
  }

  func list(_ folder: CloudBrowserFolder) async throws -> [CloudBrowserItem] {
    try await client.listFiles(folderId: folder.id, familyId: folder.familyId).map { item in
      CloudBrowserItem(
        id: item.id, name: item.name, isDirectory: item.isDirectory,
        size: item.size, modifiedAt: item.lastModified,
        isArchive: item.isArchive, isPDF: item.isPDF
      )
    }
  }

  func mountKey(for folder: CloudBrowserFolder) -> String {
    "cloud189:\(folder.familyId.map { "f\($0)" } ?? "p")/\(folder.id)"
  }

  func chapterPath(for item: CloudBrowserItem, folder: CloudBrowserFolder) -> String {
    Cloud189Path.chapter(fid: folder.familyId, fileId: item.id)
  }

  func chapterKind(for item: CloudBrowserItem) -> String {
    item.isDirectory ? "folder" : (item.isPDF ? "pdf" : "zip")
  }

  static let rootFolderId = "-11"
}
