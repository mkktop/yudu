import Foundation
import UIKit
import CryptoKit

/// 页图内存缓存：解码最长边 ≤ maxPixel；命中直接返回，未命中经页源解码
nonisolated final class PageCache: @unchecked Sendable {
  static let shared = PageCache()

  private let cache = NSCache<NSString, UIImage>()
  /// 进行中的解码去重（同页并发请求只解一次）
  private var inflight: [String: Task<UIImage?, Never>] = [:]
  private var lock = NSLock()

  private init() {
    // 超分大图单张解码后可达 30MB+，按总字节限额比按张数更稳
    cache.totalCostLimit = 512 * 1024 * 1024
    cache.countLimit = 80
  }

  private static func key(_ sourceID: String, _ index: Int, maxPixel: Int) -> NSString {
    "\(sourceID)#\(index)#\(maxPixel)" as NSString
  }

  /// 同步取（已解码过的页）
  func cached(sourceID: String, index: Int, maxPixel: Int) -> UIImage? {
    cache.object(forKey: Self.key(sourceID, index, maxPixel: maxPixel))
  }

  /// 异步取：缓存 → 去重解码 → 缓存
  func image(sourceID: String, index: Int, maxPixel: Int, loader: @escaping @Sendable () -> UIImage?) async -> UIImage? {
    if let hit = cached(sourceID: sourceID, index: index, maxPixel: maxPixel) {
      return hit
    }
    let task: Task<UIImage?, Never> = lock.withLock {
      if let existing = inflight[String(Self.key(sourceID, index, maxPixel: maxPixel))] {
        return existing
      }
      let task = Task.detached(priority: .userInitiated) { [loader] in
        loader()
      }
      inflight[String(Self.key(sourceID, index, maxPixel: maxPixel))] = task
      return task
    }
    let image = await task.value
    lock.withLock {
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

  /// 从一章第一页生成封面；成功返回 true
  func generate(
    seriesKey: String,
    chapterPath: String,
    kind: String,
    libraryRoot: URL?,
    webdavClient: WebDAVClient? = nil,
    cloud189Client: Cloud189Client? = nil
  ) async -> Bool {
    let target = coverURL(seriesKey: seriesKey)
    let sourceID = "cover:" + hashKey(seriesKey)
    guard let opened = await PageSourceFactory.open(
      chapterPath: chapterPath, kind: kind, libraryRoot: libraryRoot,
      seriesKey: seriesKey, webdavClient: webdavClient, cloud189Client: cloud189Client
    ) else {
      return false
    }
    let source = opened.source
    let image = await PageCache.shared.image(sourceID: sourceID, index: 0, maxPixel: 600) {
      source.pageImage(at: 0, maxPixel: 600)
    }
    guard let image, let jpeg = image.jpegData(compressionQuality: 0.82) else { return false }
    do {
      try jpeg.write(to: target, options: .atomic)
      return true
    } catch {
      return false
    }
  }

  func remove(seriesKey: String) {
    try? FileManager.default.removeItem(at: coverURL(seriesKey: seriesKey))
  }
}
