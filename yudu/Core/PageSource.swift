import Foundation
import UIKit
import ImageIO

/// 一话的页面数据源：按页取图与尺寸，实现自行保证线程安全
nonisolated protocol PageSource: AnyObject, Sendable {
  var pageCount: Int { get }
  /// maxPixel 为最长边的解码上限（缩放解码省内存）
  func pageImage(at index: Int, maxPixel: CGFloat) -> UIImage?
  func pageDims(at index: Int) -> CGSize?
}

// MARK: - 图片解码辅助

enum ImageDecode {
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

  /// 打开一章；rootURL 为 folder 库的授权根目录（nil 表示沙盒内无需作用域）
  nonisolated static func open(chapterPath: String, kind: String, libraryRoot: URL?) async -> OpenedSource? {
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
