import Foundation
import UIKit
import ImageIO

/// 一话的页面数据源：按页取图与尺寸，实现自行保证线程安全
nonisolated protocol PageSource: AnyObject, Sendable {
  var pageCount: Int { get }
  /// 远程/云端源：预取要更保守，尺寸探测不能整图下载
  var isRemote: Bool { get }
  /// maxPixel 为最长边的解码上限（缩放解码省内存）
  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage?
  func pageDims(at index: Int) -> CGSize?
}

extension PageSource {
  nonisolated var isRemote: Bool { false }
}

// MARK: - 图片解码辅助

nonisolated enum ImageDecode {
  /// 从原始数据解码，最长边限制在 maxPixel 内
  static func image(from data: Data, maxPixel: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return image(from: source, maxPixel: maxPixel)
  }

  static func image(from url: URL, maxPixel: CGFloat) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return image(from: source, maxPixel: maxPixel)
  }

  private static func image(from source: CGImageSource, maxPixel: CGFloat) -> UIImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return UIImage(cgImage: cg)
  }

  /// 只读尺寸不解码位图
  static func dims(from data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
          let h = props[kCGImagePropertyPixelHeight] as? CGFloat
    else { return nil }
    return CGSize(width: w, height: h)
  }

  static func dims(from url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
          let h = props[kCGImagePropertyPixelHeight] as? CGFloat
    else { return nil }
    return CGSize(width: w, height: h)
  }

  /// 从文件头（远程 Range 取到的前若干字节）解析像素尺寸，不解码整图。
  /// 支持 JPEG / PNG / GIF / WebP，其余格式交给 ImageIO 尝试解析已到的头部。
  static func dims(fromPrefix data: Data) -> CGSize? {
    let bytes = [UInt8](data.prefix(256 * 1024))
    guard bytes.count >= 16 else { return nil }

    func be16(_ i: Int) -> Int { Int(bytes[i]) << 8 | Int(bytes[i + 1]) }
    func be32(_ i: Int) -> Int {
      Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
    }
    func le16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
    func le24(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 | Int(bytes[i + 2]) << 16 }

    // PNG：IHDR 宽高
    if bytes.count >= 24,
       bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
      let w = be32(16), h = be32(20)
      if w > 0, h > 0 { return CGSize(width: w, height: h) }
    }

    // GIF：逻辑屏幕宽高
    if bytes.count >= 10,
       bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 {
      let w = le16(6), h = le16(8)
      if w > 0, h > 0 { return CGSize(width: w, height: h) }
    }

    // JPEG：扫到 SOFn 标记后读高宽
    if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 {
      var i = 2
      while i + 9 < bytes.count {
        if bytes[i] != 0xFF { i += 1; continue }
        let marker = bytes[i + 1]
        if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
          i += 2
          continue
        }
        if marker == 0xDA || marker == 0xD9 { break }
        let length = be16(i + 2)
        if length < 2 { break }
        let isSOF = (0xC0...0xCF).contains(marker)
          && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
        if isSOF {
          let h = be16(i + 5), w = be16(i + 7)
          if w > 0, h > 0 { return CGSize(width: w, height: h) }
          break
        }
        i += 2 + length
      }
    }

    // WebP：VP8X / VP8 / VP8L
    if bytes.count >= 30,
       bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
       bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
      let chunk = String(bytes: bytes[12..<16], encoding: .ascii) ?? ""
      if chunk == "VP8X" {
        let w = 1 + le24(24), h = 1 + le24(27)
        if w > 0, h > 0 { return CGSize(width: w, height: h) }
      } else if chunk == "VP8 ",
                bytes[23] == 0x9D, bytes[24] == 0x01, bytes[25] == 0x2A {
        let w = le16(26) & 0x3FFF, h = le16(28) & 0x3FFF
        if w > 0, h > 0 { return CGSize(width: w, height: h) }
      } else if chunk == "VP8L", bytes[20] == 0x2F {
        let bits = le16(21) | le16(23) << 16
        let w = (bits & 0x3FFF) + 1
        let h = ((bits >> 14) & 0x3FFF) + 1
        if w > 0, h > 0 { return CGSize(width: w, height: h) }
      }
    }

    // HEIC 等：让 ImageIO 尝试解析当前已拿到的头部
    let source = CGImageSourceCreateIncremental(nil)
    CGImageSourceUpdateData(source, Data(bytes) as CFData, false)
    if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
       let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
       let h = props[kCGImagePropertyPixelHeight] as? CGFloat,
       w > 0, h > 0 {
      return CGSize(width: w, height: h)
    }
    return nil
  }
}

// MARK: - 散图文件夹

nonisolated final class FolderPageSource: PageSource, @unchecked Sendable {
  private let urls: [URL]

  init?(folderURL: URL) {
    let keys: [URLResourceKey] = [.isDirectoryKey]
    guard let children = try? FileManager.default.contentsOfDirectory(
      at: folderURL,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else { return nil }
    var files: [URL] = []
    var subFiles: [URL] = []
    for child in children {
      let isDir = (try? child.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
      if isDir {
        // 单层子目录（分页文件夹）也当作图片来源
        if let inner = try? FileManager.default.contentsOfDirectory(
          at: child, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) {
          subFiles.append(contentsOf: inner.filter { !Self.isDirFlag($0, keys: keys) && MediaSniff.isImage($0.lastPathComponent) })
        }
      } else if MediaSniff.isImage(child.lastPathComponent) {
        files.append(child)
      }
    }
    let all = files + subFiles
    guard !all.isEmpty else { return nil }
    self.urls = all.sorted { naturalCompare($0.path, $1.path) }
  }

  private nonisolated static func isDirFlag(_ url: URL, keys: [URLResourceKey]) -> Bool {
    (try? url.resourceValues(forKeys: Set(keys)).isDirectory) ?? false
  }

  var pageCount: Int { urls.count }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    guard urls.indices.contains(index) else { return nil }
    return ImageDecode.image(from: urls[index], maxPixel: maxPixel)
  }

  func pageDims(at index: Int) -> CGSize? {
    guard urls.indices.contains(index) else { return nil }
    return ImageDecode.dims(from: urls[index])
  }
}

// MARK: - ZIP / CBZ

nonisolated final class ZipPageSource: PageSource, @unchecked Sendable {
  private let zip: ZipFile

  init(fileURL: URL) throws {
    self.zip = try ZipFile(url: fileURL)
  }

  /// 无盘模式：从内存数据读整包
  init(data: Data) throws {
    self.zip = try ZipFile(data: data)
  }

  var pageCount: Int { zip.pageCount }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    guard let data = zip.entryData(at: index) else { return nil }
    return ImageDecode.image(from: data, maxPixel: maxPixel)
  }

  func pageDims(at index: Int) -> CGSize? {
    guard let data = zip.entryData(at: index) else { return nil }
    return ImageDecode.dims(from: data)
  }
}

// MARK: - PDF

nonisolated final class PdfPageSource: PageSource, @unchecked Sendable {
  private let document: CGPDFDocument

  init?(fileURL: URL) {
    guard let doc = CGPDFDocument(fileURL as CFURL), doc.numberOfPages > 0 else { return nil }
    self.document = doc
  }

  /// 无盘模式：从内存数据读
  init?(data: Data) {
    guard let provider = CGDataProvider(data: data as CFData),
          let doc = CGPDFDocument(provider), doc.numberOfPages > 0 else { return nil }
    self.document = doc
  }

  var pageCount: Int { document.numberOfPages }

  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage? {
    // CGPDFDocument 不可变、线程安全；页码 1 起
    guard let page = document.page(at: index + 1) else { return nil }
    let bounds = page.getBoxRect(.mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let scale = min(maxPixel / max(bounds.width, bounds.height), 8)
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      ctx.cgContext.saveGState()
      ctx.cgContext.translateBy(x: 0, y: size.height)
      ctx.cgContext.scaleBy(x: scale, y: -scale)
      ctx.cgContext.drawPDFPage(page)
      ctx.cgContext.restoreGState()
    }
  }

  func pageDims(at index: Int) -> CGSize? {
    guard let page = document.page(at: index + 1) else { return nil }
    return page.getBoxRect(.mediaBox).size
  }
}

// MARK: - 安全作用域访问（授权文件夹库）

/// 对授权文件夹做引用计数的 start/stopAccessing，页源持有期间保持访问权
nonisolated final class LibraryAccess: @unchecked Sendable {
  static let shared = LibraryAccess()

  private var lock = NSLock()
  private var refcounts: [String: Int] = [:]

  private init() {}

  /// 传入解析好的 URL（已由书签恢复），返回引用；返回 nil 表示无权限（非 scoped 场景直接成功）
  func begin(url: URL?) -> AutoClose? {
    guard let url else {
      return AutoClose(key: nil) // 无需作用域（沙盒内路径）
    }
    lock.lock()
    defer { lock.unlock() }
    let key = url.path
    if refcounts[key] == nil {
      guard url.startAccessingSecurityScopedResource() else { return nil }
    }
    refcounts[key, default: 0] += 1
    return AutoClose(key: key)
  }

  fileprivate func end(key: String) {
    lock.lock()
    defer { lock.unlock() }
    guard var count = refcounts[key] else { return }
    count -= 1
    if count <= 0 {
      refcounts.removeValue(forKey: key)
      URL(fileURLWithPath: key).stopAccessingSecurityScopedResource()
    } else {
      refcounts[key] = count
    }
  }

  final class AutoClose {
    private let key: String?
    private var released = false
    private let lock = NSLock()

    init(key: String?) {
      self.key = key
    }

    deinit {
      release()
    }

    func release() {
      lock.lock()
      defer { lock.unlock() }
      guard !released, let key else { return }
      released = true
      LibraryAccess.shared.end(key: key)
    }
  }
}

// MARK: - 页源工厂

enum PageSourceFactory {

  struct OpenedSource {
    let source: any PageSource
    let access: LibraryAccess.AutoClose?
  }

  /// 打开一章；rootURL 为 folder 库的授权根目录（nil 表示沙盒内无需作用域）。
  /// WebDAV 章节（path 为 http(s) URL）需要传入客户端：zip/PDF 下载到缓存后本地读，散图逐张流式。
  /// 天翼云盘章节（path 为 cloud189://）同样传入其客户端。
  nonisolated static func open(
    chapterPath: String,
    kind: String,
    libraryRoot: URL?,
    seriesKey: String = "",
    webdavClient: WebDAVClient? = nil,
    cloud189Client: Cloud189Client? = nil,
    contentVersion: String? = nil
  ) async -> OpenedSource? {
    // 天翼云盘远程章节
    if chapterPath.hasPrefix("cloud189://"),
       let client = cloud189Client,
       let parsed = Cloud189Path.parse(chapterPath) {
      if kind == "folder" {
        guard let remote = await Cloud189FolderPageSource(
          client: client, folderId: parsed.fileId, familyId: parsed.familyId, seriesKey: seriesKey
        ) else { return nil }
        return OpenedSource(source: remote, access: LibraryAccess.shared.begin(url: nil))
      }
      // 无盘模式：zip 优先 Range 按页直读（不下载整包）
      if WebDAVCache.shared.diskless, kind == "zip" {
        let fetcher = RangeFetcher(source: .cloud189(client, fileId: parsed.fileId, familyId: parsed.familyId))
        if let remote = RemoteZipPageSource(fetcher: fetcher) {
          return OpenedSource(source: remote, access: LibraryAccess.shared.begin(url: nil))
        }
      }
      // 无盘模式：小包直接进内存（先检查大小，避免把大文件整个读进内存）
      if WebDAVCache.shared.diskless,
         let memory = try? await client.fetchData(
           fileId: parsed.fileId, familyId: parsed.familyId, sizeLimit: 600 * 1024 * 1024
         ) {
        let memorySource: (any PageSource)? = kind == "pdf"
          ? PdfPageSource(data: memory)
          : try? ZipPageSource(data: memory)
        if let memorySource {
          return OpenedSource(source: memorySource, access: LibraryAccess.shared.begin(url: nil))
        }
      }
      guard let local = try? await WebDAVCache.shared.ensureChapter(
        stableKey: chapterPath,
        ext: kind == "pdf" ? "pdf" : "zip",
        seriesKey: seriesKey,
        version: contentVersion,
        downloader: { dest in
          try await client.download(fileId: parsed.fileId, familyId: parsed.familyId, to: dest)
        }
      ) else { return nil }
      let remoteSource: (any PageSource)? = kind == "pdf"
        ? PdfPageSource(fileURL: local)
        : try? ZipPageSource(fileURL: local)
      guard let remoteSource else { return nil }
      return OpenedSource(source: remoteSource, access: LibraryAccess.shared.begin(url: nil))
    }

    // WebDAV 远程章节
    if chapterPath.hasPrefix("http") {
      guard let client = webdavClient, let url = URL(string: chapterPath) else { return nil }
      if kind == "folder" {
        guard let remote = await RemoteFolderPageSource(client: client, folderURL: url, seriesKey: seriesKey) else {
          return nil
        }
        return OpenedSource(source: remote, access: LibraryAccess.shared.begin(url: nil))
      }
      if WebDAVCache.shared.diskless, kind == "zip" {
        let fetcher = RangeFetcher(source: .webdav(client, url))
        if let remote = RemoteZipPageSource(fetcher: fetcher) {
          return OpenedSource(source: remote, access: LibraryAccess.shared.begin(url: nil))
        }
      }
      if WebDAVCache.shared.diskless,
         let memory = await client.fetchDataLimited(url, limit: 600 * 1024 * 1024) {
        let memorySource: (any PageSource)? = kind == "pdf"
          ? PdfPageSource(data: memory)
          : try? ZipPageSource(data: memory)
        if let memorySource {
          return OpenedSource(source: memorySource, access: LibraryAccess.shared.begin(url: nil))
        }
      }
      guard let local = try? await WebDAVCache.shared.ensureChapter(
        url: url, seriesKey: seriesKey, client: client, version: contentVersion
      ) else {
        return nil
      }
      let remoteSource: (any PageSource)? = kind == "pdf"
        ? PdfPageSource(fileURL: local)
        : try? ZipPageSource(fileURL: local)
      guard let remoteSource else { return nil }
      return OpenedSource(source: remoteSource, access: LibraryAccess.shared.begin(url: nil))
    }

    let url = URL(fileURLWithPath: chapterPath)
    // 需要 scoped 访问的：章节路径就在授权目录下
    let needsScope = libraryRoot != nil && chapterPath.hasPrefix(libraryRoot!.path)
    let token: LibraryAccess.AutoClose?
    if needsScope {
      token = LibraryAccess.shared.begin(url: libraryRoot)
      if token == nil { return nil }
    } else {
      token = LibraryAccess.shared.begin(url: nil)
    }
    let source: (any PageSource)?
    switch kind {
    case "zip":
      source = try? ZipPageSource(fileURL: url)
    case "pdf":
      source = PdfPageSource(fileURL: url)
    default:
      source = FolderPageSource(folderURL: url)
    }
    guard let source else {
      token?.release()
      return nil
    }
    return OpenedSource(source: source, access: token)
  }

}
