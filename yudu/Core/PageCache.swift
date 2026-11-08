import Foundation
import UIKit
import CryptoKit
import os

/// 页图内存缓存：按 key（源#页码#解码上限，≤0 为原图）缓存解码位图；命中直接返回，未命中经页源解码
nonisolated final class PageCache: @unchecked Sendable {
  static let shared = PageCache()

  private let cache = NSCache<NSString, UIImage>()
  /// 进行中的解码去重：解码完成（含失败）才移除条目，
  /// 等待期间不会被先完成的等待者误删，避免同页并发时重复解码大图。
  private var inflight: [String: InflightBox] = [:]
  private var lock = NSLock()

  /// 引用盒：Task 是值类型没法比身份，用类实例判断「仍是当前那次解码」。
  /// seats 记录还在等结果的调用方数量；全部退席（任务被取消）才取消底层解码，
  /// 前台 / 预取 / 条漫并发请求同一页时互不误伤。
  private final class InflightBox: @unchecked Sendable {
    var task: Task<UIImage?, Never>?
    private let seatLock = NSLock()
    private var seats = 0

    func addSeat() {
      seatLock.withLock { seats += 1 }
    }

    /// 幂等：onCancel 与 await 正常结束后的退席可能都触发
    func removeSeat() {
      seatLock.withLock {
        guard seats > 0 else { return }
        seats -= 1
        // 最后一个等待者走了：排队中的解码直接跳过，不再占用线程池
        if seats == 0 { task?.cancel() }
      }
    }
  }

  private init() {
    // 按设备物理内存分档：8GB+ 给 1.5GB，6GB+ 给 1GB，其余 512MB。
    // 大内存机器多驻留原图，回翻基本不再重新解码；
    // NSCache 在系统内存吃紧时会自动清空，是安全的可牺牲缓存，给多了也无害。
    let physical = ProcessInfo.processInfo.physicalMemory
    if physical >= 8 << 30 {
      cache.totalCostLimit = 1536 << 20
    } else if physical >= 6 << 30 {
      cache.totalCostLimit = 1 << 30
    } else {
      cache.totalCostLimit = 512 << 20
    }
    // 数量上限给宽（条漫一章常见一两百页），实际淘汰由上面的内存成本主导
    cache.countLimit = 240
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
  /// 取消语义：调用方任务被取消即退席；同页的所有等待者都退席后才取消底层解码
  /// （排队中的操作直接跳过），谁先取消都不影响其他还在等的调用方。
  /// 撞上被撤销的航班（nil）时重试一次新开解码——快速连翻时预取频繁被撤销，
  /// 跟在其后的前台请求不能把别人的取消当成自己的加载失败。
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
    for _ in 0..<2 {
      let outcome = await decodeOnce(
        sourceID: sourceID, index: index, maxPixel: maxPixel,
        priority: priority, loader: loader
      )
      if let image = outcome.image { return image }
      // 等到 nil 有两种可能：真的解码失败，或等的那班解码已被撤销
      //（撤销前已开跑的会跑完并落缓存，image 非空，不会走到这里）。
      // 只有后者才值得重试；真失败重试只会白费一次解码。
      guard outcome.wasCancelled, !Task.isCancelled else { return nil }
    }
    return nil
  }

  private func decodeOnce(
    sourceID: String, index: Int, maxPixel: Int,
    priority: TaskPriority,
    loader: @escaping @Sendable () -> UIImage?
  ) async -> (image: UIImage?, wasCancelled: Bool) {
    let key = String(Self.key(sourceID, index, maxPixel: maxPixel))
    let box: InflightBox = lock.withLock {
      // 已撤销的航班不复用：它注定返回 nil，等它只会得到假失败。
      // 换新 box 后旧航班的 finishInflight 有 === 身份判断，不会误删新条目。
      if let existing = inflight[key], existing.task?.isCancelled != true { return existing }
      let box = InflightBox()
      box.task = Task.detached(priority: priority) { [loader] in
        let image = await PageLoadExecutor.shared.run(priority: priority) {
          autoreleasepool { loader() }
        }
        // 先落缓存再清 inflight：两步之间到达的新请求会走缓存命中，
        // 反过来的顺序会留下一个"缓存没有、去重也没有"的空窗，开出重复解码
        if let image {
          PageCache.shared.cache.setObject(
            image, forKey: Self.key(sourceID, index, maxPixel: maxPixel),
            cost: Int(image.size.width * image.size.height * 4)
          )
        }
        PageCache.shared.finishInflight(key: key, box: box)
        return image
      }
      inflight[key] = box
      return box
    }
    // 席位 = 一个等待者；任务被取消时 onCancel 退席，最后一个退席的取消排队中的解码
    box.addSeat()
    let image = await withTaskCancellationHandler {
      await box.task!.value
    } onCancel: {
      box.removeSeat()
    }
    box.removeSeat() // 正常结束也退席
    return (image, box.task?.isCancelled == true)
  }

  /// 解码收尾：只有仍是当前那次解码时才清条目（期间可能已被新解码替换）
  private func finishInflight(key: String, box: InflightBox) {
    lock.withLock {
      if inflight[key] === box { inflight.removeValue(forKey: key) }
    }
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
