import Foundation
import UIKit

// MARK: - 天翼云盘扫描（章节 path 用 cloud189:// 伪 URL，fileId 稳定可做缓存键）

nonisolated enum Cloud189Path {
  /// "cloud189://<f<familyId>|p>/<fileId>"
  static func chapter(fid: String?, fileId: String) -> String {
    "cloud189://\(fid.map { "f\($0)" } ?? "p")/\(fileId)"
  }

  static func parse(_ path: String) -> (familyId: String?, fileId: String)? {
    guard path.hasPrefix("cloud189://") else { return nil }
    let body = String(path.dropFirst("cloud189://".count))
    guard let slash = body.firstIndex(of: "/") else { return nil }
    let scope = String(body[..<slash])
    let fileId = String(body[body.index(after: slash)...])
    guard !fileId.isEmpty else { return nil }
    let familyId = scope.hasPrefix("f") ? String(scope.dropFirst()) : nil
    return (familyId, fileId)
  }
}

nonisolated enum Cloud189Scanner {

  static func scanLibrary(client: Cloud189Client, rootFolderId: String, familyId: String?, libraryKey: String) async -> ScanReport {
    var series: [ScannedSeries] = []
    var errors: [String] = []

    let rootItems: [Cloud189Item]
    do {
      rootItems = try await client.listFiles(folderId: rootFolderId, familyId: familyId)
    } catch {
      return ScanReport(series: [], errors: [error.localizedDescription])
    }

    for item in rootItems.sorted(by: { naturalCompare($0.name, $1.name) }) {
      if item.isDirectory {
        if let s = await scanSeriesFolder(client: client, folder: item, familyId: familyId, libraryKey: libraryKey) {
          series.append(s)
        } else {
          errors.append("目录无内容或读取失败：\(item.name)")
        }
      } else if item.isArchive || item.isPDF {
        let parsed = FilenameParser.parseChapter(item.name)
        series.append(
          ScannedSeries(
            key: "\(libraryKey)/\(item.name)",
            title: parsed.cleanTitle,
            chapters: [
              ScannedChapter(
                path: Cloud189Path.chapter(fid: familyId, fileId: item.id),
                title: parsed.cleanTitle,
                volume: parsed.volume,
                number: parsed.number,
                kind: item.isPDF ? "pdf" : "zip",
                pageCount: 0,
                size: item.size,
                mtime: item.lastModified ?? .distantPast
              )
            ]
          )
        )
      }
    }
    return ScanReport(series: series, errors: errors)
  }

  private static func scanSeriesFolder(client: Cloud189Client, folder: Cloud189Item, familyId: String?, libraryKey: String) async -> ScannedSeries? {
    guard let children = try? await client.listFiles(folderId: folder.id, familyId: familyId) else { return nil }

    var chapters: [ScannedChapter] = []
    var looseImages = 0

    for child in children {
      if child.isDirectory {
        if let inner = try? await client.listFiles(folderId: child.id, familyId: familyId) {
          let count = inner.filter(\.isImage).count
          if count > 0 {
            chapters.append(makeChapter(item: child, familyId: familyId, kind: "folder", pages: count))
          }
        }
      } else if child.isImage {
        looseImages += 1
      } else if child.isArchive || child.isPDF {
        chapters.append(makeChapter(item: child, familyId: familyId, kind: child.isPDF ? "pdf" : "zip", pages: 0))
      }
    }

    if chapters.isEmpty && looseImages > 0 {
      chapters.append(makeChapter(item: folder, familyId: familyId, kind: "folder", pages: looseImages))
    }
    guard !chapters.isEmpty else { return nil }

    return ScannedSeries(
      key: "\(libraryKey)/\(folder.name)",
      title: folder.name,
      chapters: LibraryScanner.sortChapters(chapters)
    )
  }

  private static func makeChapter(item: Cloud189Item, familyId: String?, kind: String, pages: Int) -> ScannedChapter {
    let parsed = FilenameParser.parseChapter(item.name)
    return ScannedChapter(
      path: Cloud189Path.chapter(fid: familyId, fileId: item.id),
      title: parsed.cleanTitle,
      volume: parsed.volume,
      number: parsed.number,
      kind: kind,
      pageCount: pages,
      size: item.size,
      mtime: item.lastModified ?? .distantPast
    )
  }
}

// MARK: - 天翼散图章节页源（逐张流式，fileId 做缓存键）

nonisolated final class Cloud189FolderPageSource: PageSource, @unchecked Sendable {
  private let client: Cloud189Client
  private let familyId: String?
  private let images: [Cloud189Item]
  private let seriesKey: String

  init?(client: Cloud189Client, folderId: String, familyId: String?, seriesKey: String) async {
    guard let items = try? await client.listFiles(folderId: folderId, familyId: familyId) else { return nil }
    let images = items.filter(\.isImage).sorted { naturalCompare($0.name, $1.name) }
    guard !images.isEmpty else { return nil }
    self.client = client
    self.familyId = familyId
    self.images = images
    self.seriesKey = seriesKey
  }

  var pageCount: Int { images.count }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    load(index: index).flatMap { ImageDecode.image(from: $0, maxPixel: maxPixel) }
  }

  func pageDims(at index: Int) -> CGSize? {
    load(index: index).flatMap { ImageDecode.dims(from: $0) }
  }

  /// 稳定缓存键：伪 URL 内含 fileId
  private var cacheURLs: [URL] {
    images.map { URL(string: "cloud189://img/\($0.id).\(MediaSniff.extensionOf($0.name))")! }
  }

  private func load(index: Int) -> Data? {
    guard images.indices.contains(index) else { return nil }
    let cacheKey = cacheURLs[index]
    if let local = WebDAVCache.shared.imageURL(for: cacheKey),
       let data = try? Data(contentsOf: local) {
      return data
    }
    let image = images[index]
    guard let data = try? client.fetchDataSync(fileId: image.id, familyId: familyId) else { return nil }
    WebDAVCache.shared.storeImage(data, for: cacheKey, seriesKey: seriesKey)
    return data
  }

  func prefetchAll() async {
    let keys = cacheURLs
    for (index, image) in images.enumerated() {
      if WebDAVCache.shared.imageURL(for: keys[index]) != nil { continue }
      if let data = try? await client.fetchData(fileId: image.id, familyId: familyId) {
        WebDAVCache.shared.storeImage(data, for: keys[index], seriesKey: seriesKey)
      }
    }
  }
}

extension Cloud189Client {
  /// 后台解码线程的同步取图（页源用）
  func fetchDataSync(fileId: String, familyId: String?) -> Data? {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Data?
    Task.detached {
      result = try? await self.fetchData(fileId: fileId, familyId: familyId)
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }
}
