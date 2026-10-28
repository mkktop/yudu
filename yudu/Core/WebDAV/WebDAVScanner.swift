import Foundation
import CryptoKit
import UIKit

// MARK: - WebDAV 扫描（结构与本地扫描一致：根目录子文件夹=系列、压缩包=话）

nonisolated enum WebDAVScanner {

  static func scanLibrary(client: WebDAVClient, root: URL, libraryKey: String) async -> ScanReport {
    var series: [ScannedSeries] = []
    var errors: [String] = []

    let rootItems: [WebDAVItem]
    do {
      rootItems = try await client.list(root)
    } catch {
      return ScanReport(series: [], errors: [error.localizedDescription])
    }

    for item in rootItems.sorted(by: { naturalCompare($0.name, $1.name) }) {
      if item.isDirectory {
        if let s = await scanSeriesFolder(client: client, folder: item, libraryKey: libraryKey) {
          series.append(s)
        } else {
          errors.append("目录无内容或读取失败：\(item.name)")
        }
      } else if item.isArchive || item.isPDF {
        let kind = item.isPDF ? "pdf" : "zip"
        // 云端 zip/PDF 不整包下载，页数未知（阅读时回填，对齐桌面版）
        let parsed = FilenameParser.parseChapter(item.name)
        series.append(
          ScannedSeries(
            key: "\(libraryKey)/\(item.name)",
            title: parsed.cleanTitle,
            chapters: [
              ScannedChapter(
                path: item.url.absoluteString,
                title: parsed.cleanTitle,
                volume: parsed.volume,
                number: parsed.number,
                kind: kind,
                pageCount: 0,
                size: item.contentLength,
                mtime: item.lastModified ?? .distantPast
              )
            ]
          )
        )
      }
    }
    return ScanReport(series: series, errors: errors)
  }

  private static func scanSeriesFolder(client: WebDAVClient, folder: WebDAVItem, libraryKey: String) async -> ScannedSeries? {
    guard let children = try? await client.list(folder.url) else { return nil }

    var chapters: [ScannedChapter] = []
    var looseImages = 0

    for child in children {
      if child.isDirectory {
        // 散图子文件夹 = 一话（多一次 PROPFIND 数图片）
        if let inner = try? await client.list(child.url) {
          let count = inner.filter(\.isImage).count
          if count > 0 {
            chapters.append(makeChapter(item: child, kind: "folder", pages: count))
          }
        }
      } else if child.isImage {
        looseImages += 1
      } else if child.isArchive || child.isPDF {
        chapters.append(makeChapter(item: child, kind: child.isPDF ? "pdf" : "zip", pages: 0))
      }
    }

    if chapters.isEmpty && looseImages > 0 {
      chapters.append(makeChapter(item: folder, kind: "folder", pages: looseImages))
    }
    guard !chapters.isEmpty else { return nil }

    return ScannedSeries(
      key: "\(libraryKey)/\(folder.name)",
      title: folder.name,
      chapters: LibraryScanner.sortChapters(chapters)
    )
  }

  private static func makeChapter(item: WebDAVItem, kind: String, pages: Int) -> ScannedChapter {
    let parsed = FilenameParser.parseChapter(item.name)
    return ScannedChapter(
      path: item.url.absoluteString,
      title: parsed.cleanTitle,
      volume: parsed.volume,
      number: parsed.number,
      kind: kind,
      pageCount: pages,
      size: item.contentLength,
      mtime: item.lastModified ?? .distantPast
    )
  }
}

// MARK: - WebDAV 缓存（章节整包 / 散图单张 + 容量上限 + 离线保护）

nonisolated final class WebDAVCache: @unchecked Sendable {
  static let shared = WebDAVCache()

  struct Entry: Codable {
    var url: String
    var seriesKey: String
    var size: Int64
    var at: Date
  }

  private let dir: URL
  private let imgDir: URL
  private let manifestURL: URL
  private let lock = NSLock()
  private var manifest: [String: Entry]

  static let capKey = "webdavCacheCapBytes"
  static let pinnedKey = "webdavPinnedSeries"

  var capBytes: Int64 {
    get { UserDefaults.standard.object(forKey: Self.capKey) as? Int64 ?? 2 * 1024 * 1024 * 1024 }
    set { UserDefaults.standard.set(newValue, forKey: Self.capKey) }
  }

  /// 无盘模式（容量设为 0）：阅读时不写硬盘，整包进内存直接读；手动“离线缓存”不受影响
  var diskless: Bool { capBytes == 0 }

  /// 已离线预取完成的系列（同时受清理保护）
  var pinnedSeries: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: Self.pinnedKey) ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: Self.pinnedKey) }
  }

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    dir = caches.appendingPathComponent("webdav", isDirectory: true)
    imgDir = dir.appendingPathComponent("img", isDirectory: true)
    manifestURL = dir.appendingPathComponent("manifest.json")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: manifestURL),
       let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
      manifest = decoded
    } else {
      manifest = [:]
    }
  }

  // MARK: 键与路径

  private func hashKey(_ url: URL) -> String {
    hashKeyString(url.absoluteString)
  }

  private func hashKeyString(_ text: String) -> String {
    let digest = SHA256.hash(data: Data(text.utf8))
    return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
  }

  func chapterCacheURL(for url: URL) -> URL? {
    let target = dir.appendingPathComponent(hashKey(url) + "." + MediaSniff.extensionOf(url.lastPathComponent))
    return FileManager.default.fileExists(atPath: target.path) ? target : nil
  }

  func imageURL(for url: URL) -> URL? {
    let target = imgDir.appendingPathComponent(hashKey(url) + "." + MediaSniff.extensionOf(url.lastPathComponent))
    return FileManager.default.fileExists(atPath: target.path) ? target : nil
  }

  // MARK: 章节整包（zip / pdf）

  /// 缓存命中直接返回，否则下载
  func ensureChapter(url: URL, seriesKey: String, client: WebDAVClient) async throws -> URL {
    try await ensureChapter(
      stableKey: url.absoluteString,
      ext: MediaSniff.extensionOf(url.lastPathComponent),
      seriesKey: seriesKey
    ) { dest in
      try await client.download(url, to: dest)
    }
  }

  /// 通用章节缓存：稳定键 + 自定义下载器（天翼云盘用 fileId 做键，直链有时效不能做键）
  func ensureChapter(
    stableKey: String,
    ext: String,
    seriesKey: String,
    downloader: @escaping @Sendable (URL) async throws -> Void
  ) async throws -> URL {
    let key = hashKeyString(stableKey)
    let target = dir.appendingPathComponent(key + "." + ext)
    if FileManager.default.fileExists(atPath: target.path) {
      touch(key: key)
      return target
    }
    try await downloader(target)
    let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    lock.lock()
    manifest[key] = Entry(url: stableKey, seriesKey: seriesKey, size: size, at: .now)
    lock.unlock()
    persistManifest()
    evictIfNeeded()
    return target
  }

  // MARK: 散图单张

  func storeImage(_ data: Data, for url: URL, seriesKey: String? = nil) {
    let key = hashKey(url)
    let target = imgDir.appendingPathComponent(key + "." + MediaSniff.extensionOf(url.lastPathComponent))
    try? data.write(to: target, options: .atomic)
    if let seriesKey {
      lock.lock()
      manifest["img-" + key] = Entry(url: url.absoluteString, seriesKey: seriesKey, size: Int64(data.count), at: .now)
      lock.unlock()
      persistManifest()
    }
  }

  // MARK: 统计与清理

  func usageBytes() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    return manifest.values.reduce(0) { $0 + $1.size }
  }

  /// 清掉某书库的缓存（按 seriesKey 前缀匹配）
  func removeLibrary(prefix libraryKey: String) {
    lock.lock()
    let doomed = manifest.filter { $0.value.seriesKey.hasPrefix(libraryKey) }
    for (key, _) in doomed { manifest.removeValue(forKey: key) }
    lock.unlock()
    for (key, _) in doomed {
      deleteFile(key: key.replacingOccurrences(of: "img-", with: ""),
                 extensions: MediaSniff.imageExtensions.union(["zip", "cbz", "pdf"]),
                 bothDirs: true)
    }
    persistManifest()
  }

  func clearAll() {
    lock.lock()
    manifest.removeAll()
    lock.unlock()
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
    persistManifest()
    pinnedSeries = []
  }

  /// 超容量时按最久未用清理；离线保护的系列不动
  func evictIfNeeded() {
    let pinned = pinnedSeries
    lock.lock()
    let total = manifest.values.reduce(0) { $0 + $1.size }
    guard total > capBytes else {
      lock.unlock()
      return
    }
    var victims = manifest
      .filter { !pinned.contains($0.value.seriesKey) }
      .sorted { $0.value.at < $1.value.at }
    var freed: Int64 = 0
    let need = total - capBytes + 64 * 1024 * 1024 // 多清 64MB 余量
    var doomedKeys: [String] = []
    while freed < need, !victims.isEmpty {
      let (key, entry) = victims.removeFirst()
      manifest.removeValue(forKey: key)
      doomedKeys.append(key)
      freed += entry.size
    }
    lock.unlock()
    for key in doomedKeys {
      deleteFile(key: key.replacingOccurrences(of: "img-", with: ""),
                 extensions: MediaSniff.imageExtensions.union(["zip", "cbz", "pdf"]),
                 bothDirs: true)
    }
    persistManifest()
  }

  private func deleteFile(key: String, extensions: Set<String>, bothDirs: Bool) {
    for ext in extensions {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(key).\(ext)"))
      if bothDirs {
        try? FileManager.default.removeItem(at: imgDir.appendingPathComponent("\(key).\(ext)"))
      }
    }
  }

  private func touch(key: String) {
    lock.lock()
    if manifest[key] != nil {
      manifest[key]?.at = .now
    }
    lock.unlock()
    persistManifest()
  }

  private func persistManifest() {
    lock.lock()
    let snapshot = manifest
    lock.unlock()
    if let data = try? JSONEncoder().encode(snapshot) {
      try? data.write(to: manifestURL, options: .atomic)
    }
  }
}

// MARK: - WebDAV 散图章节页源（逐张流式 + 磁盘缓存）

nonisolated final class RemoteFolderPageSource: PageSource, @unchecked Sendable {
  private let client: WebDAVClient
  private let images: [WebDAVItem]
  private let seriesKey: String

  init?(client: WebDAVClient, folderURL: URL, seriesKey: String) async {
    guard let items = try? await client.list(folderURL) else { return nil }
    let images = items
      .filter(\.isImage)
      .sorted { naturalCompare($0.name, $1.name) }
    guard !images.isEmpty else { return nil }
    self.client = client
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

  private func load(index: Int) -> Data? {
    guard images.indices.contains(index) else { return nil }
    let url = images[index].url
    if let local = WebDAVCache.shared.imageURL(for: url),
       let data = try? Data(contentsOf: local) {
      return data
    }
    guard let data = client.getSync(url) else { return nil }
    if !WebDAVCache.shared.diskless {
      WebDAVCache.shared.storeImage(data, for: url, seriesKey: seriesKey)
    }
    return data
  }

  /// 离线预取：全部图片拉到本地缓存
  func prefetchAll() async -> Bool {
    var complete = true
    for image in images {
      guard !Task.isCancelled else { return false }
      if WebDAVCache.shared.imageURL(for: image.url) != nil { continue }
      if let data = try? await client.get(image.url) {
        guard !Task.isCancelled else { return false }
        WebDAVCache.shared.storeImage(data, for: image.url, seriesKey: seriesKey)
        if WebDAVCache.shared.imageURL(for: image.url) == nil { complete = false }
      } else { complete = false }
    }
    return complete
  }
}
