import Foundation
import CryptoKit
import UIKit

// MARK: - WebDAV 扫描（结构与本地/天翼扫描一致：形状分类 volume/wrapper/series + 布局装配）

nonisolated enum WebDAVScanner {

  static func scanLibrary(
    client: WebDAVClient, root: URL, libraryKey: String, libraryName: String,
    mode: LibraryScanMode = .incremental, layout: LibraryScanLayout = .multi
  ) async -> ScanReport {
    var errors: [String] = []
    var isComplete = true
    let previousCache = ScanCache.load(libraryKey: libraryKey)
    var cache: [String: CachedChildScan] = [:]

    await ReaderActivity.waitWhileReading()
    let rootItems: [WebDAVItem]
    do {
      rootItems = try await client.list(root)
    } catch {
      return ScanReport(series: [], errors: [error.localizedDescription], isComplete: false)
    }

    var dirs: [(name: String, child: ClassifiedChild?)] = []
    var archiveChapters: [ScannedChapter] = []
    var archiveSeries: [ScannedSeries] = []

    // 根目录子项逐个比对指纹：没变化就直接复用上次结果，不再下钻。
    for item in rootItems.sorted(by: { naturalCompare($0.name, $1.name) }) {
      await ReaderActivity.waitWhileReading()
      let key = item.url.absoluteString
      let fingerprint = fingerprint(of: item)
      if let cached = previousCache[key],
         ScanCache.canReuse(cached, fingerprint: fingerprint, mode: mode) {
        dirs.append((item.name, ClassifiedChild(kind: cached.kind, series: cached.series, chapters: cached.chapters)))
        cache[key] = cached
        continue
      }

      if item.isDirectory {
        guard let entry = await classifyWebDAVDir(
          client: client, folder: item, libraryKey: libraryKey,
          previousPages: previousCache[key]?.folderPages ?? [:], mode: mode
        ) else {
          errors.append("目录读取失败：\(item.name)")
          isComplete = false
          dirs.append((item.name, nil))
          if let old = previousCache[key] { cache[key] = old }
          continue
        }
        dirs.append((item.name, ClassifiedChild(kind: entry.kind, series: entry.series, chapters: entry.chapters)))
        if !entry.complete {
          errors.append("目录读取失败：\(item.name)")
          isComplete = false
        }
        cache[key] = entry
      } else if item.isArchive || item.isPDF {
        let entry = archiveEntry(item: item, libraryKey: libraryKey)
        if let scanned = entry.series {
          archiveSeries.append(scanned)
        }
        archiveChapters += entry.chapters
        cache[key] = entry
      }
    }

    ScanCache.save(cache, libraryKey: libraryKey)
    return LibraryScanner.assembleLibrary(
      dirs: dirs, archiveChapters: archiveChapters, archiveSeries: archiveSeries,
      libraryKey: libraryKey, libraryName: libraryName,
      layout: layout, errors: errors, isComplete: isComplete
    )
  }

  /// 判定根子目录形状（结构对齐 Cloud189Scanner.scanRootDirectory）：
  /// volume = 直接装着图片/包；wrapper = 子项全是「直接装媒体」的文件夹（卷壳）；series = 其余。
  private static func classifyWebDAVDir(
    client: WebDAVClient, folder: WebDAVItem, libraryKey: String,
    previousPages: [String: CachedFolderPages], mode: LibraryScanMode
  ) async -> CachedChildScan? {
    guard let children = try? await client.list(folder.url) else { return nil }

    var pageCache: [String: CachedFolderPages] = [:]
    var complete = true
    var kind = "series"
    var wrapperChapters: [ScannedChapter] = []

    let hasDirectMedia = children.contains { !$0.isDirectory && ($0.isImage || $0.isArchive || $0.isPDF) }
    if hasDirectMedia {
      kind = "volume"
    } else {
      let subDirs = children.filter(\.isDirectory)
      if !subDirs.isEmpty, subDirs.count == children.count {
        var allMedia = true
        for sub in subDirs {
          await ReaderActivity.waitWhileReading()
          guard let stats = await imageStats(
            client: client, folder: sub, previous: previousPages, cache: &pageCache, mode: mode
          ) else {
            complete = false
            allMedia = false
            break
          }
          guard stats.hasMedia else { allMedia = false; break }
          wrapperChapters.append(makeChapter(item: sub, kind: "folder", pages: stats.pageCount))
        }
        if allMedia { kind = "wrapper" }
      }
    }

    var chapters: [ScannedChapter] = []
    switch kind {
    case "volume":
      chapters = [makeChapter(item: folder, kind: "folder", pages: 0)]
    case "wrapper":
      chapters = wrapperChapters.sorted { naturalCompare($0.title, $1.title) }
    default:
      break
    }

    // series 拆解（multi 布局用；single 布局也复用它的章节列表）
    let (series, seriesComplete) = await scanSeriesContent(
      client: client, folder: folder, children: children, libraryKey: libraryKey,
      previousPages: previousPages, cache: &pageCache, mode: mode
    )
    if !seriesComplete { complete = false }

    return CachedChildScan(
      fingerprint: fingerprint(of: folder),
      kind: kind,
      series: series,
      chapters: chapters,
      folderPages: pageCache,
      complete: complete,
      scannedAt: .now,
      volatile: isVolatile(folder)
    )
  }

  /// 系列内容拆解（子文件夹/包 = 话；纯散图整目录一话）。children 由调用方传入，避免重复列目录。
  private static func scanSeriesContent(
    client: WebDAVClient, folder: WebDAVItem, children: [WebDAVItem], libraryKey: String,
    previousPages: [String: CachedFolderPages],
    cache: inout [String: CachedFolderPages], mode: LibraryScanMode
  ) async -> (ScannedSeries?, Bool) {
    var chapters: [ScannedChapter] = []
    var complete = true

    for child in children {
      await ReaderActivity.waitWhileReading()
      if child.isDirectory {
        guard let stats = await imageStats(
          client: client, folder: child, previous: previousPages, cache: &cache, mode: mode
        ) else {
          complete = false
          continue
        }
        if stats.pageCount > 0 {
          chapters.append(makeChapter(item: child, kind: "folder", pages: stats.pageCount))
        }
      } else if child.isArchive || child.isPDF {
        chapters.append(makeChapter(item: child, kind: child.isPDF ? "pdf" : "zip", pages: 0))
      }
    }

    // 纯散图系列：整个文件夹就是一话；散图与章节共存时，明显的散图内容（≥3 张）也补一章
    let looseImages = children.filter(\.isImage).count
    if looseImages > 0 && (chapters.isEmpty || looseImages >= 3) {
      chapters.append(makeChapter(item: folder, kind: "folder", pages: looseImages))
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

  /// 散图子目录的统计（页数 + 是否直接装媒体）：目录指纹没变就复用上次结果，省掉一次 PROPFIND。
  private static func imageStats(
    client: WebDAVClient, folder: WebDAVItem,
    previous: [String: CachedFolderPages], cache: inout [String: CachedFolderPages], mode: LibraryScanMode
  ) async -> CachedFolderPages? {
    let key = folder.url.absoluteString
    let fingerprint = fingerprint(of: folder)
    if mode == .incremental, folder.lastModified != nil,
       let cached = previous[key], cached.fingerprint == fingerprint {
      cache[key] = cached
      return cached
    }
    guard let inner = try? await client.list(folder.url) else { return nil }
    let stats = CachedFolderPages(
      fingerprint: fingerprint,
      pageCount: inner.filter(\.isImage).count,
      hasMedia: inner.contains { !$0.isDirectory && ($0.isImage || $0.isArchive || $0.isPDF) }
    )
    cache[key] = stats
    return stats
  }

  private static func fingerprint(of item: WebDAVItem) -> String {
    let mtime = item.lastModified.map { String(Int($0.timeIntervalSince1970)) } ?? "none"
    return "\(item.url.absoluteString)|\(item.name)|\(item.isDirectory ? "d" : "f")|\(item.contentLength)|\(mtime)"
  }

  private static func isVolatile(_ item: WebDAVItem) -> Bool {
    item.lastModified == nil
  }

  private static func archiveEntry(item: WebDAVItem, libraryKey: String) -> CachedChildScan {
    let chapter = makeChapter(item: item, kind: item.isPDF ? "pdf" : "zip", pages: 0)
    return CachedChildScan(
      fingerprint: fingerprint(of: item),
      kind: "archive",
      series: ScannedSeries(key: "\(libraryKey)/\(item.name)", title: chapter.title, chapters: [chapter]),
      chapters: [chapter],
      folderPages: [:],
      complete: true,
      scannedAt: .now,
      volatile: isVolatile(item)
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

  struct Entry: Codable, Sendable {
    var url: String
    var seriesKey: String
    var size: Int64
    var at: Date
    /// 远端文件版本（mtime + size）；变化后缓存自动失效。
    var version: String? = nil
  }

  private let dir: URL
  private let imgDir: URL
  private let manifestURL: URL
  private let lock = NSLock()
  private var manifest: [String: Entry]
  /// 手动离线期间保护该系列，避免下载过程中被容量清理删掉。
  private var protectedSeries: Set<String> = []
  /// 同一章节并发请求只下载一次。
  private var inflight: [String: Task<URL, Error>] = [:]
  /// 清单落盘串行队列：读页/写图时不阻塞调用线程。
  private let ioQueue = DispatchQueue(label: "com.mkk.yudu.webdav-cache-io", qos: .utility)
  private var pendingPersist = false

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
    // debounce 期间退到后台时补一次落盘，避免清单长时间不写。
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: nil
      ) { [weak self] _ in
        self?.persistManifestNow()
      }
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
  func ensureChapter(url: URL, seriesKey: String, client: WebDAVClient, version: String? = nil) async throws -> URL {
    try await ensureChapter(
      stableKey: url.absoluteString,
      ext: MediaSniff.extensionOf(url.lastPathComponent),
      seriesKey: seriesKey,
      version: version
    ) { dest in
      try await client.download(url, to: dest)
    }
  }

  /// 通用章节缓存：稳定键 + 自定义下载器（天翼云盘用 fileId 做键，直链有时效不能做键）
  func ensureChapter(
    stableKey: String,
    ext: String,
    seriesKey: String,
    version: String? = nil,
    downloader: @escaping @Sendable (URL) async throws -> Void
  ) async throws -> URL {
    let key = hashKeyString(stableKey)
    let target = dir.appendingPathComponent(key + "." + ext)

    if let cached = cachedChapter(key: key, target: target, version: version) {
      return cached
    }

    // 同一章节的并发请求合并成一个下载任务。
    let task: Task<URL, Error> = lock.withLock {
      if let existing = inflight[key] { return existing }
      let task = Task { [self] in
        // 等锁外再检查一次，避免两个调用同时判定未命中。
        if let cached = cachedChapter(key: key, target: target, version: version) {
          return cached
        }
        try await downloader(target)
        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else { throw WebDAVClient.WebDAVError.unreachable("下载文件为空") }
        lock.withLock {
          manifest[key] = Entry(url: stableKey, seriesKey: seriesKey, size: size, at: .now, version: version)
        }
        persistManifestNow()
        evictIfNeeded()
        return target
      }
      inflight[key] = task
      return task
    }

    do {
      let result = try await task.value
      _ = lock.withLock { inflight.removeValue(forKey: key) }
      return result
    } catch {
      _ = lock.withLock { inflight.removeValue(forKey: key) }
      throw error
    }
  }

  private func cachedChapter(key: String, target: URL, version: String?) -> URL? {
    guard FileManager.default.fileExists(atPath: target.path) else { return nil }
    let entry = lock.withLock { manifest[key] }
    if let version, entry?.version != version {
      // 旧版本或远端文件已变化：删掉重下。
      try? FileManager.default.removeItem(at: target)
      return nil
    }
    touch(key: key)
    return target
  }

  /// 手动离线开始/结束保护（容量清理会跳过这些系列）。
  func protect(seriesKey: String) {
    lock.withLock { _ = protectedSeries.insert(seriesKey) }
  }

  func unprotect(seriesKey: String) {
    lock.withLock { _ = protectedSeries.remove(seriesKey) }
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
      persistManifestSoon()
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
    protectedSeries = protectedSeries.filter { !$0.hasPrefix(libraryKey) }
    lock.unlock()
    for (key, _) in doomed {
      deleteFile(key: key.replacingOccurrences(of: "img-", with: ""),
                 extensions: MediaSniff.imageExtensions.union(["zip", "cbz", "pdf"]),
                 bothDirs: true)
    }
    persistManifestNow()
  }

  func clearAll() {
    lock.lock()
    manifest.removeAll()
    protectedSeries.removeAll()
    lock.unlock()
    try? FileManager.default.removeItem(at: dir)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
    persistManifestNow()
    pinnedSeries = []
  }

  /// 超容量时按最久未用清理；离线保护和手动缓存中的系列不动
  func evictIfNeeded() {
    let pinned = pinnedSeries
    lock.lock()
    let protected = protectedSeries
    let total = manifest.values.reduce(0) { $0 + $1.size }
    guard total > capBytes else {
      lock.unlock()
      return
    }
    var victims = manifest
      .filter { !pinned.contains($0.value.seriesKey) && !protected.contains($0.value.seriesKey) }
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
    persistManifestNow()
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
    persistManifestSoon()
  }

  /// 结构性变化（章节下载完成、清理、移除书库）立即排队落盘。
  private func persistManifestNow() {
    let snapshot = lock.withLock { manifest }
    let url = manifestURL
    ioQueue.async {
      if let data = try? JSONEncoder().encode(snapshot) {
        try? data.write(to: url, options: .atomic)
      }
    }
  }

  /// 高频变化（散图写入、浏览命中刷新 LRU）合并成 1 秒一次，避免每页都重写整份清单。
  private func persistManifestSoon() {
    let shouldSchedule: Bool = lock.withLock {
      if pendingPersist { return false }
      pendingPersist = true
      return true
    }
    guard shouldSchedule else { return }
    ioQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self else { return }
      self.lock.withLock { self.pendingPersist = false }
      self.persistManifestNow()
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

  var isRemote: Bool { true }

  var pageCount: Int { images.count }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    load(index: index).flatMap { ImageDecode.image(from: $0, maxPixel: maxPixel) }
  }

  /// 尺寸只读图片头（Range 256KB），不再为拿宽高下载整页原图。
  func pageDims(at index: Int) -> CGSize? {
    guard images.indices.contains(index) else { return nil }
    let item = images[index]
    let key = cacheURL(for: item)
    if let local = WebDAVCache.shared.imageURL(for: key),
       let data = try? Data(contentsOf: local) {
      return ImageDecode.dims(from: data)
    }
    guard let prefix = client.getPrefixSync(item.url, length: 256 * 1024) else { return nil }
    return ImageDecode.dims(fromPrefix: prefix)
  }

  /// 缓存键带上远端 mtime/size，文件更新后旧图自动失效。
  private func cacheURL(for item: WebDAVItem) -> URL {
    var components = URLComponents(url: item.url, resolvingAgainstBaseURL: false)
    let version = "\(item.lastModified?.timeIntervalSince1970 ?? 0)-\(item.contentLength)"
    components?.queryItems = [URLQueryItem(name: "v", value: version)]
    return components?.url ?? item.url
  }

  private func load(index: Int) -> Data? {
    guard images.indices.contains(index) else { return nil }
    let item = images[index]
    let key = cacheURL(for: item)
    if let local = WebDAVCache.shared.imageURL(for: key),
       let data = try? Data(contentsOf: local) {
      return data
    }
    guard let data = client.getSync(item.url) else { return nil }
    if !WebDAVCache.shared.diskless {
      WebDAVCache.shared.storeImage(data, for: key, seriesKey: seriesKey)
    }
    return data
  }

  /// 离线预取：全部图片拉到本地缓存
  func prefetchAll() async -> Bool {
    var complete = true
    for image in images {
      guard !Task.isCancelled else { return false }
      let key = cacheURL(for: image)
      if WebDAVCache.shared.imageURL(for: key) != nil { continue }
      if let data = try? await client.get(image.url) {
        guard !Task.isCancelled else { return false }
        WebDAVCache.shared.storeImage(data, for: key, seriesKey: seriesKey)
        if WebDAVCache.shared.imageURL(for: key) == nil { complete = false }
      } else { complete = false }
    }
    return complete
  }
}
