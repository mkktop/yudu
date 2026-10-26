import Foundation
import UIKit
import Compression

// MARK: - 按需加载：Range 字节段读取器（WebDAV / 天翼云盘共用）

/// 同步 Range 读取（在后台解码线程调用；天翼直链有时效，失效自动换新）
nonisolated final class RangeFetcher: @unchecked Sendable {
  enum Source {
    case webdav(WebDAVClient, URL)
    case cloud189(Cloud189Client, fileId: String, familyId: String?)
  }

  private let source: Source
  private let lock = NSLock()
  private var directURL: URL? // cloud189 直链缓存
  private var total: Int64 = -1

  init(source: Source) {
    self.source = source
  }

  /// 文件总大小（Range 0-0 探测，读 Content-Range）
  func totalSize() -> Int64? {
    if total > 0 { return total }
    guard let head = read(offset: 0, length: 1), !head.isEmpty else { return nil }
    return total > 0 ? total : nil
  }

  /// 读一段字节；服务器不支持 206 时返回 nil（调用方回退整包路径）
  func read(offset: Int, length: Int) -> Data? {
    guard length > 0 else { return Data() }
    for attempt in 0..<2 {
      guard let url = currentURL(rebinding: attempt > 0) else { return nil }
      var req = URLRequest(url: url)
      req.httpMethod = "GET"
      req.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
      req.timeoutInterval = 30
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var payload: Data?
      nonisolated(unsafe) var status = 0
      nonisolated(unsafe) var contentRange: String?
      URLSession.shared.dataTask(with: req) { data, resp, _ in
        status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        contentRange = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")
        payload = data
        semaphore.signal()
      }.resume()
      semaphore.wait()

      if status == 206, let payload {
        if total < 0, let range = contentRange,
           let sizePart = range.split(separator: "/").last, let size = Int64(sizePart) {
          total = size
        }
        return payload
      }
      // 直链过期（403/410）→ 换新直链重试；其他情况（200 全量=不支持 Range）放弃
      if attempt == 0, status == 403 || status == 410 {
        lock.lock(); directURL = nil; lock.unlock()
        continue
      }
      return nil
    }
    return nil
  }

  private func currentURL(rebinding: Bool) -> URL? {
    switch source {
    case .webdav(_, let url):
      return url
    case .cloud189(let client, let fileId, let familyId):
      lock.lock()
      let cached = directURL
      lock.unlock()
      if let cached, !rebinding { return cached }
      // 同步解析直链
      let semaphore = DispatchSemaphore(value: 0)
      nonisolated(unsafe) var resolved: URL?
      Task.detached {
        resolved = try? await client.downloadURL(fileId: fileId, familyId: familyId)
        semaphore.signal()
      }
      semaphore.wait()
      guard let url = resolved else { return nil }
      lock.lock(); directURL = url; lock.unlock()
      return url
    }
  }
}

// MARK: - 远程 zip 按页直读（中央目录 + 单页字节段，不下载整包）

nonisolated final class RemoteZipPageSource: PageSource, @unchecked Sendable {
  private let fetcher: RangeFetcher
  private let entries: [ZipFile.Entry]

  enum RemoteZipError: Error, LocalizedError {
    case noRangeSupport
    var errorDescription: String? { "服务器不支持分段下载" }
  }

  init?(fetcher: RangeFetcher) {
    self.fetcher = fetcher
    guard let total = fetcher.totalSize(), total > 22 else { return nil }
    // EOCD 在文件尾 64KB+22 内；ZipFile 的定位算法直接可用于尾部窗口
    let tailLength = Int(min(UInt64(65_558), UInt64(total)))
    guard let tail = fetcher.read(offset: Int(total) - tailLength, length: tailLength) else {
      return nil
    }
    guard let (centralOffset, centralSize, _) = try? ZipFile.locateCentralDirectoryPublic(tail) else {
      return nil
    }
    guard let central = fetcher.read(offset: Int(centralOffset), length: Int(centralSize)) else {
      return nil
    }
    guard let parsed = ZipFile.parseCentralDirectorySlice(central) else { return nil }
    let pages = parsed.filter { ZipFile.isPageEntryName($0.name) }
    guard !pages.isEmpty else { return nil }
    self.entries = pages.sorted { naturalCompare($0.name, $1.name) }
  }

  var pageCount: Int { entries.count }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    entryData(at: index).flatMap { ImageDecode.image(from: $0, maxPixel: maxPixel) }
  }

  func pageDims(at index: Int) -> CGSize? {
    entryData(at: index).flatMap { ImageDecode.dims(from: $0) }
  }

  /// 单页三段请求：本地头(30B+名长) → 压缩字节 → 解压
  private func entryData(at index: Int) -> Data? {
    guard entries.indices.contains(index) else { return nil }
    let entry = entries[index]
    let lho = Int(entry.localHeaderOffset)
    guard let header = fetcher.read(offset: lho, length: 30 + 512) else { return nil }
    guard header.count > 30,
          UInt32(header[0]) | (UInt32(header[1]) << 8) | (UInt32(header[2]) << 16) | (UInt32(header[3]) << 24) == 0x04034B50
    else { return nil }
    func u16(_ o: Int) -> Int { Int(header[o]) | (Int(header[o + 1]) << 8) }
    let dataStart = 30 + u16(26) + u16(28)
    let compLen = Int(entry.compressedSize)
    guard let payload = fetcher.read(offset: lho + dataStart, length: compLen), payload.count == compLen else {
      return nil
    }
    switch entry.method {
    case 0:
      return payload
    case 8:
      let out = Int(entry.uncompressedSize)
      guard out > 0, out < 400 * 1024 * 1024 else { return nil }
      var dst = Data(count: out)
      let written = dst.withUnsafeMutableBytes { dstPtr in
        payload.withUnsafeBytes { srcPtr in
          compression_decode_buffer(
            dstPtr.bindMemory(to: UInt8.self).baseAddress!, out,
            srcPtr.bindMemory(to: UInt8.self).baseAddress!, payload.count,
            nil, COMPRESSION_ZLIB
          )
        }
      }
      guard written == out else { return nil }
      return dst
    default:
      return nil
    }
  }
}
