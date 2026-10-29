import Foundation
import UIKit
import CryptoKit
import os

/// 页图内存缓存：解码最长边 ≤ maxPixel；命中直接返回，未命中经页源解码
nonisolated final class PageCache: @unchecked Sendable {
  static let shared = PageCache()

  private let cache = NSCache<NSString, UIImage>()
  /// 进行中的解码去重（同页并发请求只解一次）
  private var inflight: [String: Task<UIImage?, Never>] = [:]
  private var lock = NSLock()

  private init() {
    // 按设备物理内存定上限：6GB 以上给 1GB，老的给 512MB
    // （NSCache 在系统内存吃紧时会自动清空，是安全的可牺牲缓存）
    let physical = ProcessInfo.processInfo.physicalMemory
    cache.totalCostLimit = physical >= 6 << 30 ? 1 << 30 : 512 * 1024 * 1024
    cache.countLimit = 80
  }

  private static func key(_ sourceID: String, _ index: Int, maxPixel: Int) -> NSString {
    "\(sourceID)#\(index)#\(maxPixel)" as NSString
  }

  /// 同步取（已解码过的页）
  func cached(sourceID: String, index: Int, maxPixel: Int) -> UIImage? {
    cache.object(forKey: Self.key(sourceID, index, maxPixel: maxPixel))
  }

  /// 异步取：缓存 → 去重解码 → 缓存。
  /// 加载本身跑在专用有界线程池，页源里的同步网络桥接不会阻塞 Swift 并发池。
  func image(
    sourceID: String, index: Int, maxPixel: Int,
    priority: TaskPriority = .userInitiated,
    loader: @escaping @Sendable () -> UIImage?
  ) async -> UIImage? {
    if let hit = cached(sourceID: sourceID, index: index, maxPixel: maxPixel) {
      Perf.signposter.emitEvent("page-cache-hit")
      return hit
    }
    let interval = Perf.signposter.beginInterval("page-load")
    defer { Perf.signposter.endInterval("page-load", interval) }
    let task: Task<UIImage?, Never> = lock.withLock {
      if let existing = inflight[String(Self.key(sourceID, index, maxPixel: maxPixel))] {
        return existing
      }
      let task = Task.detached(priority: priority) { [loader] in
        await PageLoadExecutor.shared.run(priority: priority) {
          autoreleasepool { loader() }
        }
      }
      inflight[String(Self.key(sourceID, index, maxPixel: maxPixel))] = task
      return task
    }
    let image = await task.value
    _ = lock.withLock {
      inflight.removeValue(forKey: String(Self.key(sourceID, index, maxPixel: maxPixel)))
    }
    if let image {
      cache.setObject(image, forKey: Self.key(sourceID, index, maxPixel: maxPixel),
                      cost: Int(image.size.width * image.size.height * 4))
    }
    return image
  }

  func clear() {
    cache.removeAllObjects()
  }
}

/// 系列封面：磁盘缓存（Caches/covers），扫描时生成
nonisolated final class CoverStore: @unchecked Sendable {
  static let shared = CoverStore()

  private let dir: URL

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    dir = caches.appendingPathComponent("covers", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  private func hashKey(_ seriesKey: String) -> String {
    let digest = SHA256.hash(data: Data(seriesKey.utf8))
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  func coverURL(seriesKey: String) -> URL {
    dir.appendingPathComponent(hashKey(seriesKey) + ".jpg")
  }

  func hasCover(seriesKey: String) -> Bool {
    FileManager.default.fileExists(atPath: coverURL(seriesKey: seriesKey).path)
  }

  /// 封面文件比源章节旧则需要重画。
  func isFresh(seriesKey: String, sourceModifiedAt: Date) -> Bool {
    let target = coverURL(seriesKey: seriesKey)
    guard FileManager.default.fileExists(atPath: target.path) else { return false }
    guard sourceModifiedAt > .distantPast else { return true }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
          let coverDate = attrs[.modificationDate] as? Date
    else { return true }
    return coverDate >= sourceModifiedAt
  }

  /// 从一章第一页生成封面；成功返回 true
  func generate(
    seriesKey: String,
    chapterPath: String,
    kind: String,
    libraryRoot: URL?,
    webdavClient: WebDAVClient? = nil,
    cloud189Client: Cloud189Client? = nil,
    contentVersion: String? = nil
  ) async -> Bool {
    let target = coverURL(seriesKey: seriesKey)
    let sourceID = "cover:" + hashKey(seriesKey) + ":" + (contentVersion ?? "")

    func save(_ image: UIImage?) -> Bool {
      guard let image, let jpeg = image.jpegData(compressionQuality: 0.82) else { return false }
      do {
        try jpeg.write(to: target, options: .atomic)
        return true
      } catch {
        return false
      }
    }

    // WebDAV / 天翼 zip：只读中央目录和第一页，不下载整包。
    if kind == "zip", let webdavClient, let url = URL(string: chapterPath) {
      let fetcher = RangeFetcher(source: .webdav(webdavClient, url))
      if let remote = RemoteZipPageSource(fetcher: fetcher) {
        let image = await PageCache.shared.image(sourceID: sourceID, index: 0, maxPixel: 600) {
          remote.pageImage(at: 0, maxPixel: 600)
        }
        if save(image) { return true }
      }
    }
    if kind == "zip", let cloud189Client, let parsed = Cloud189Path.parse(chapterPath) {
      let fetcher = RangeFetcher(
        source: .cloud189(cloud189Client, fileId: parsed.fileId, familyId: parsed.familyId)
      )
      if let remote = RemoteZipPageSource(fetcher: fetcher) {
        let image = await PageCache.shared.image(sourceID: sourceID, index: 0, maxPixel: 600) {
          remote.pageImage(at: 0, maxPixel: 600)
        }
        if save(image) { return true }
      }
    }

    guard let opened = await PageSourceFactory.open(
      chapterPath: chapterPath, kind: kind, libraryRoot: libraryRoot,
      seriesKey: seriesKey, webdavClient: webdavClient, cloud189Client: cloud189Client,
      contentVersion: contentVersion
    ) else {
      return false
    }
    let source = opened.source
    let image = await PageCache.shared.image(sourceID: sourceID, index: 0, maxPixel: 600) {
      source.pageImage(at: 0, maxPixel: 600)
    }
    return save(image)
  }

  func remove(seriesKey: String) {
    try? FileManager.default.removeItem(at: coverURL(seriesKey: seriesKey))
  }
}
