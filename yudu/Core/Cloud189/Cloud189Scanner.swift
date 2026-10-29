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

  static func scanLibrary(
    client: Cloud189Client, rootFolderId: String, familyId: String?, libraryKey: String, libraryName: String,
    mode: LibraryScanMode = .incremental,
    onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
  ) async -> ScanReport {
    var errors: [String] = []
    var isComplete = true
    let previousCache = ScanCache.load(libraryKey: libraryKey)
    var cache: [String: CachedChildScan] = [:]

    await ReaderActivity.waitWhileReading()
    let rootItems: [Cloud189Item]
    do {
      rootItems = try await client.listFiles(folderId: rootFolderId, familyId: familyId)
    } catch {
      return ScanReport(series: [], errors: [error.localizedDescription], isComplete: false)
    }

    let rootDirs = rootItems.filter(\.isDirectory).sorted(by: { naturalCompare($0.name, $1.name) })
    let rootArchives = rootItems.filter { !$0.isDirectory && ($0.isArchive || $0.isPDF) }
    let total = rootDirs.count + rootArchives.count

    // 根目录子项逐个比对指纹：没变化就直接复用上次结果，不再下钻。
    var dirEntries: [String: CachedChildScan] = [:]
    for (index, dir) in rootDirs.enumerated() {
      await ReaderActivity.waitWhileReading()
      onProgress?(index, total, "检查目录：\(dir.name)")
      let fingerprint = fingerprint(of: dir)
      if let cached = previousCache[dir.id],
         ScanCache.canReuse(cached, fingerprint: fingerprint, mode: mode) {
        dirEntries[dir.id] = cached
        cache[dir.id] = cached
        continue
      }
      guard let entry = await scanRootDirectory(
        client: client, dir: dir, familyId: familyId, libraryKey: libraryKey,
        previousPages: previousCache[dir.id]?.folderPages ?? [:], mode: mode
      ) else {
        errors.append("目录读取失败：\(dir.name)")
        isComplete = false
        if let old = previousCache[dir.id] { cache[dir.id] = old }
        continue
      }
      dirEntries[dir.id] = entry
      cache[dir.id] = entry
      if !entry.complete {
        errors.append("目录读取失败：\(dir.name)")
        isComplete = false
      }
    }

    var archiveEntries: [String: CachedChildScan] = [:]
    for (offset, item) in rootArchives.sorted(by: { naturalCompare($0.name, $1.name) }).enumerated() {
      onProgress?(rootDirs.count + offset, total, item.name)
      let fingerprint = fingerprint(of: item)
      if let cached = previousCache[item.id],
         ScanCache.canReuse(cached, fingerprint: fingerprint, mode: mode) {
        archiveEntries[item.id] = cached
        cache[item.id] = cached
        continue
      }
      let entry = archiveEntry(item: item, familyId: familyId, libraryKey: libraryKey)
      archiveEntries[item.id] = entry
      cache[item.id] = entry
    }

    ScanCache.save(cache, libraryKey: libraryKey)

    // 布局识别（对齐桌面版 cloud/scanner）：
    // volume=直接含图片/压缩包  wrapper=子目录全是卷（同名嵌套包装层）  series=独立作品
    let classified = rootDirs.compactMap { dirEntries[$0.id] }
    let singleSeries = !classified.isEmpty
      && classified.count == rootDirs.count
      && classified.allSatisfy { $0.kind != "series" }

    if singleSeries {
      // 单系列库：挂载的整个目录就是一部作品（卷文件夹/嵌套包装层展开/散包都是章节）
      var chapters: [ScannedChapter] = []
      for item in rootArchives.sorted(by: { naturalCompare($0.name, $1.name) }) {
        chapters += archiveEntries[item.id]?.chapters ?? []
      }
      for dir in rootDirs {
        chapters += dirEntries[dir.id]?.chapters ?? []
      }
      if !chapters.isEmpty {
        return ScanReport(
          series: [ScannedSeries(key: libraryKey, title: libraryName, chapters: LibraryScanner.sortChapters(chapters))],
          errors: errors,
          isComplete: isComplete
        )
      }
      return ScanReport(series: [], errors: errors, isComplete: isComplete)
    }

    // 多系列：根下每个目录一部作品（内部再分章节），散包各自成单文件系列
    var series: [ScannedSeries] = []
    for dir in rootDirs {
      guard let entry = dirEntries[dir.id] else { continue }
      if let scanned = entry.series {
        series.append(scanned)
      } else if entry.complete {
        errors.append("目录无内容：\(dir.name)")
      }
    }
    for item in rootArchives.sorted(by: { naturalCompare($0.name, $1.name) }) {
      if let scanned = archiveEntries[item.id]?.series {
        series.append(scanned)
      }
    }
    return ScanReport(series: series, errors: errors, isComplete: isComplete)
  }

  /// 扫描根目录下的一个子目录，同时产出两种布局需要的结果：
  /// 多系列布局 → series；单系列布局 → chapters。
  private static func scanRootDirectory(
    client: Cloud189Client, dir: Cloud189Item, familyId: String?, libraryKey: String,
    previousPages: [String: CachedFolderPages], mode: LibraryScanMode
  ) async -> CachedChildScan? {
    await ReaderActivity.waitWhileReading()
    guard let children = try? await client.listFiles(folderId: dir.id, familyId: familyId) else {
      return nil
    }

    var pageCache: [String: CachedFolderPages] = [:]
    var complete = true
    var kind = "series"
    var wrapperVolumes: [Cloud189Item] = []

    let hasDirectMedia = children.contains {
      !$0.isDirectory && ($0.isImage || $0.isArchive || $0.isPDF)
    }
    if hasDirectMedia {
      kind = "volume"
    } else {
      let subDirs = children.filter(\.isDirectory)
      if !subDirs.isEmpty, subDirs.count == children.count {
        var allVolumes = true
        var volumes: [Cloud189Item] = []
        for sub in subDirs {
          await ReaderActivity.waitWhileReading()
          guard let stats = await folderStats(
            client: client, folder: sub, familyId: familyId,
            previous: previousPages, cache: &pageCache, mode: mode
          ) else {
            complete = false
            allVolumes = false
            break
          }
          guard stats.hasMedia else {
            allVolumes = false
            break
          }
          volumes.append(sub)
        }
        if allVolumes {
          kind = "wrapper"
          wrapperVolumes = volumes
        }
      }
    }

    var chapters: [ScannedChapter] = []
    switch kind {
    case "volume":
      chapters = [makeChapter(item: dir, familyId: familyId, kind: "folder", pages: 0)]
    case "wrapper":
      chapters = wrapperVolumes
        .sorted { naturalCompare($0.name, $1.name) }
        .map { makeChapter(item: $0, familyId: familyId, kind: "folder", pages: 0) }
    default:
      break
    }

    let (series, seriesComplete) = await makeSeries(
      client: client, folder: dir, children: children, familyId: familyId, libraryKey: libraryKey,
      previous: previousPages, cache: &pageCache, mode: mode
    )
    if !seriesComplete { complete = false }

    return CachedChildScan(
      fingerprint: fingerprint(of: dir),
      kind: kind,
      series: series,
      chapters: chapters,
      folderPages: pageCache,
      complete: complete,
      scannedAt: .now,
      volatile: isVolatile(dir)
    )
  }

  private static func makeSeries(
    client: Cloud189Client, folder: Cloud189Item, children: [Cloud189Item], familyId: String?, libraryKey: String,
    previous: [String: CachedFolderPages], cache: inout [String: CachedFolderPages], mode: LibraryScanMode
  ) async -> (ScannedSeries?, Bool) {
    var chapters: [ScannedChapter] = []
    var looseImages = 0
    var complete = true

    for child in children {
      await ReaderActivity.waitWhileReading()
      if child.isDirectory {
        guard let stats = await folderStats(
          client: client, folder: child, familyId: familyId,
          previous: previous, cache: &cache, mode: mode
        ) else {
          complete = false
          continue
        }
        if stats.pageCount > 0 {
          chapters.append(makeChapter(item: child, familyId: familyId, kind: "folder", pages: stats.pageCount))
        }
      } else if child.isImage {
        looseImages += 1
      } else if child.isArchive || child.isPDF {
        chapters.append(makeChapter(item: child, familyId: familyId, kind: child.isPDF ? "pdf" : "zip", pages: 0))
      }
    }

    // 目录里散图与章节共存时，散图整体也算一章（对齐桌面版）
    if looseImages > 0 {
      chapters.append(makeChapter(item: folder, familyId: familyId, kind: "folder", pages: looseImages))
    }
    guard !chapters.isEmpty else { return (nil, complete) }

    return (
      ScannedSeries(
        key: "\(libraryKey)/\(folder.name)",
        title: folder.name,
        chapters: LibraryScanner.sortChapters(chapters)
      ),
      complete
    )
  }

  /// 散图子目录的图片数与内容判定：目录指纹没变就复用上次结果，省掉一次目录请求。
  private static func folderStats(
    client: Cloud189Client, folder: Cloud189Item, familyId: String?,
    previous: [String: CachedFolderPages], cache: inout [String: CachedFolderPages], mode: LibraryScanMode
  ) async -> CachedFolderPages? {
    let fingerprint = fingerprint(of: folder)
    if mode == .incremental, folder.lastModified != nil,
       let cached = previous[folder.id], cached.fingerprint == fingerprint {
      cache[folder.id] = cached
      return cached
    }
    guard let inner = try? await client.listFiles(folderId: folder.id, familyId: familyId) else {
      return nil
    }
    let stats = CachedFolderPages(
      fingerprint: fingerprint,
      pageCount: inner.filter(\.isImage).count,
      hasMedia: inner.contains { !$0.isDirectory && ($0.isImage || $0.isArchive || $0.isPDF) }
    )
    cache[folder.id] = stats
    return stats
  }

  private static func fingerprint(of item: Cloud189Item) -> String {
    let mtime = item.lastModified.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
    return "\(item.id)|\(item.name)|\(item.isDirectory ? "d" : "f")|\(item.size)|\(mtime)"
  }

  private static func isVolatile(_ item: Cloud189Item) -> Bool {
    item.lastModified == nil
  }

  private static func archiveEntry(
    item: Cloud189Item, familyId: String?, libraryKey: String
  ) -> CachedChildScan {
    let parsed = FilenameParser.parseChapter(item.name)
    let chapter = ScannedChapter(
      path: Cloud189Path.chapter(fid: familyId, fileId: item.id),
      title: parsed.cleanTitle,
      volume: parsed.volume,
      number: parsed.number,
      kind: item.isPDF ? "pdf" : "zip",
      pageCount: 0,
      size: item.size,
      mtime: item.lastModified ?? .distantPast
    )
    return CachedChildScan(
      fingerprint: fingerprint(of: item),
      kind: "archive",
      series: ScannedSeries(key: "\(libraryKey)/\(item.name)", title: parsed.cleanTitle, chapters: [chapter]),
      chapters: [chapter],
      folderPages: [:],
      complete: true,
      scannedAt: .now,
      volatile: isVolatile(item)
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
  /// 读尺寸只需图片头，取 256KB 足够覆盖 EXIF/ICC 后的 SOF
  private static let dimsPrefixBytes = 256 * 1024

  private let client: Cloud189Client
  private let familyId: String?
  private let images: [Cloud189Item]
  private let seriesKey: String
  /// 稳定缓存键：伪 URL 内含 fileId，并带上远端 mtime/size 以便文件更新后失效。
  private let cacheKeys: [URL]

  init?(client: Cloud189Client, folderId: String, familyId: String?, seriesKey: String) async {
    guard let items = try? await client.listFiles(folderId: folderId, familyId: familyId) else { return nil }
    let images = items.filter(\.isImage).sorted { naturalCompare($0.name, $1.name) }
    guard !images.isEmpty else { return nil }
    self.client = client
    self.familyId = familyId
    self.images = images
    self.seriesKey = seriesKey
    self.cacheKeys = images.map { image in
      let version = "\(image.lastModified?.timeIntervalSince1970 ?? 0)-\(image.size)"
      return URL(string: "cloud189://img/\(image.id).\(MediaSniff.extensionOf(image.name))?v=\(version)")!
    }
  }

  var isRemote: Bool { true }

  var pageCount: Int { images.count }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    load(index: index).flatMap { ImageDecode.image(from: $0, maxPixel: maxPixel) }
  }

  /// 尺寸只读图片头（Range 256KB），不再为拿宽高下载整页 40MB 原图。
  func pageDims(at index: Int) -> CGSize? {
    guard images.indices.contains(index) else { return nil }
    let cacheKey = cacheKeys[index]
    if let local = WebDAVCache.shared.imageURL(for: cacheKey),
       let data = try? Data(contentsOf: local) {
      return ImageDecode.dims(from: data)
    }
    guard let prefix = client.fetchPrefixSync(
      fileId: images[index].id, familyId: familyId, length: Self.dimsPrefixBytes
    ) else { return nil }
    return ImageDecode.dims(fromPrefix: prefix)
  }

  private func load(index: Int) -> Data? {
    guard images.indices.contains(index) else { return nil }
    let cacheKey = cacheKeys[index]
    if let local = WebDAVCache.shared.imageURL(for: cacheKey),
       let data = try? Data(contentsOf: local) {
      return data
    }
    let image = images[index]
    guard let data = client.fetchDataSync(fileId: image.id, familyId: familyId) else { return nil }
    if !WebDAVCache.shared.diskless {
      WebDAVCache.shared.storeImage(data, for: cacheKey, seriesKey: seriesKey)
    }
    return data
  }

  func prefetchAll() async -> Bool {
    var complete = true
    for (index, image) in images.enumerated() {
      guard !Task.isCancelled else { return false }
      if WebDAVCache.shared.imageURL(for: cacheKeys[index]) != nil { continue }
      if let data = try? await client.fetchData(fileId: image.id, familyId: familyId) {
        guard !Task.isCancelled else { return false }
        WebDAVCache.shared.storeImage(data, for: cacheKeys[index], seriesKey: seriesKey)
        if WebDAVCache.shared.imageURL(for: cacheKeys[index]) == nil { complete = false }
      } else { complete = false }
    }
    return complete
  }
}

extension Cloud189Client {
  /// 后台解码线程的同步取图（页源用）
  nonisolated func fetchDataSync(fileId: String, familyId: String?) -> Data? {
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
