import Foundation
import CoreGraphics

// MARK: - 扫描结果（纯值类型，后台产出，主线程落库）

struct ScannedChapter {
  var path: String
  var title: String
  var volume: String?
  var number: Double?
  var kind: String
  var pageCount: Int
  var size: Int64
  var mtime: Date
}

struct ScannedSeries {
  var key: String
  var title: String
  var chapters: [ScannedChapter]
}

struct ScanReport {
  var series: [ScannedSeries]
  var errors: [String]
}

// MARK: - 扫描器（跑在后台执行器）

/// 规则与桌面版一致：库根目录的子文件夹 = 系列；根目录散装压缩包/PDF = 单文件系列；
/// 系列内的压缩包 / 散图子文件夹 = 话；系列根只有散图时整个文件夹算一话。
/// chapters 顺序即 sortIndex 顺序（有话号按话号升序在前，无话号自然序在后）。
nonisolated enum LibraryScanner {

  static func scanLibraryRoot(root: URL) -> ScanReport {
    var series: [ScannedSeries] = []
    var errors: [String] = []

    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else {
      return ScanReport(series: [], errors: ["无法读取目录：\(root.path)"])
    }

    for child in children.sorted(by: { naturalCompare($0.lastPathComponent, $1.lastPathComponent) }) {
      let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        if let s = scanSeriesFolder(child, libraryKey: root.path) {
          series.append(s)
        } else {
          let empty = ((try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: nil)) ?? []).isEmpty
          if !empty { errors.append("文件夹内没有可读内容：\(child.lastPathComponent)") }
        }
      } else if MediaSniff.isArchive(child.lastPathComponent) || MediaSniff.isPDF(child.lastPathComponent) {
        if let s = scanSingleFile(child, libraryKey: root.path) {
          series.append(s)
        } else {
          errors.append("无法读取：\(child.lastPathComponent)")
        }
      }
      // 其他类型文件忽略
    }
    return ScanReport(series: series, errors: errors)
  }

  /// 单个压缩包 / PDF 作为一个系列（导入文件、库根散装文件共用）
  static func scanSingleFile(_ url: URL, libraryKey: String) -> ScannedSeries? {
    guard let kind = MediaSniff.chapterKind(url: url), kind != "folder" else { return nil }
    let chapter = makeChapter(url: url, kind: kind)
    return ScannedSeries(
      key: "\(libraryKey)/\(url.lastPathComponent)",
      title: FilenameParser.parseChapter(url.lastPathComponent).cleanTitle,
      chapters: [chapter]
    )
  }

  /// 一个系列文件夹 → 系列与它的章节
  static func scanSeriesFolder(_ folder: URL, libraryKey: String) -> ScannedSeries? {
    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return nil }

    var chapters: [ScannedChapter] = []
    var looseImages = 0

    for child in children {
      let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        let images = (try? fm.contentsOfDirectory(
          at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ))?.filter { MediaSniff.isImage($0.lastPathComponent) } ?? []
        if !images.isEmpty {
          chapters.append(makeChapter(url: child, kind: "folder", pages: images.count))
        }
      } else if MediaSniff.isImage(child.lastPathComponent) {
        looseImages += 1
      } else if MediaSniff.isArchive(child.lastPathComponent) || MediaSniff.isPDF(child.lastPathComponent) {
        if let kind = MediaSniff.chapterKind(url: child) {
          chapters.append(makeChapter(url: child, kind: kind))
        }
      }
    }

    // 整个文件夹就是一话（纯散图系列）
    if chapters.isEmpty && looseImages > 0 {
      chapters.append(makeChapter(url: folder, kind: "folder", pages: looseImages))
    }

    guard !chapters.isEmpty else { return nil }

    return ScannedSeries(
      key: "\(libraryKey)/\(folder.lastPathComponent)",
      title: folder.lastPathComponent,
      chapters: sortChapters(chapters)
    )
  }

  private static func makeChapter(url: URL, kind: String, pages: Int? = nil) -> ScannedChapter {
    let parsed = FilenameParser.parseChapter(url.lastPathComponent)
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
      ?? .distantPast
    var pageCount = pages ?? 0
    if pages == nil {
      switch kind {
      case "zip":
        if let zip = try? ZipFile(url: url) { pageCount = zip.pageCount }
      case "pdf":
        if let doc = CGPDFDocument(url as CFURL) { pageCount = doc.numberOfPages }
      default:
        let children = (try? FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        pageCount = children.filter { MediaSniff.isImage($0.lastPathComponent) }.count
      }
    }
    return ScannedChapter(
      path: url.path,
      title: parsed.cleanTitle,
      volume: parsed.volume,
      number: parsed.number,
      kind: kind,
      pageCount: pageCount,
      size: size,
      mtime: mtime
    )
  }

  /// 话排序：有话号在前按话号升序，无话号按自然序排后
  static func sortChapters(_ chapters: [ScannedChapter]) -> [ScannedChapter] {
    chapters.sorted { a, b in
      switch (a.number, b.number) {
      case let (na?, nb?) where na != nb:
        return na < nb
      case (.some, nil):
        return true
      case (nil, .some):
        return false
      default:
        if a.volume != b.volume, let va = a.volume, let vb = b.volume {
          return naturalCompare(va, vb)
        }
        return naturalCompare(a.title, b.title)
      }
    }
  }
}
