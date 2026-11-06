import Foundation
import CoreGraphics

// MARK: - 扫描结果（纯值类型，后台产出，主线程落库）

struct ScannedChapter: Codable {
  var path: String
  var title: String
  var volume: String?
  var number: Double?
  var kind: String
  var pageCount: Int
  var size: Int64
  var mtime: Date
}

struct ScannedSeries: Codable {
  var key: String
  var title: String
  var chapters: [ScannedChapter]
}

struct ScanReport {
  var series: [ScannedSeries]
  var errors: [String]
  /// false 表示扫描过程中有目录/网络读取失败，结果不完整。
  /// 此时调用方只能新增或更新，不能删除旧系列/旧章节，否则一次掉线就会清空书库。
  var isComplete: Bool = true
}

/// 书库目录结构：multi = 每个子文件夹是一部漫画（默认，经典库结构）；
/// single = 整个文件夹是一部漫画（子文件夹/压缩包都是话）。由用户在导入时选择，可随时改。
enum LibraryScanLayout: String, Codable, Sendable {
  case multi
  case single
}

/// 书库根子目录的形状判定（三种扫描器共用）：kind = volume | wrapper | series
struct ClassifiedChild {
  var kind: String
  /// multi 布局下的系列（series 形状才有；volume/wrapper 形状为 nil）
  var series: ScannedSeries?
  /// single 布局下的章节（volume = 目录本身；wrapper = 各卷；series = 它拆出的章节）
  var chapters: [ScannedChapter]
}

// MARK: - 扫描器（跑在后台执行器）

/// 基础规则：库根目录的子文件夹 = 系列；根目录散装压缩包/PDF = 单文件系列；
/// 系列内的压缩包 / 散图子文件夹 = 话；系列根只有散图时整个文件夹算一话。
/// 目录结构（单部/多部）按 LibraryScanLayout 装配，见 assembleLibrary。
/// chapters 顺序即 sortIndex 顺序（有话号按话号升序在前，无话号自然序在后）。
nonisolated enum LibraryScanner {

  static func scanLibraryRoot(root: URL, layout: LibraryScanLayout = .multi) -> ScanReport {
    var errors: [String] = []
    var isComplete = true

    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else {
      return ScanReport(series: [], errors: ["无法读取目录：\(root.path)"], isComplete: false)
    }

    var dirs: [(name: String, child: ClassifiedChild?)] = []
    var archiveChapters: [ScannedChapter] = []
    var archiveSeries: [ScannedSeries] = []
    for child in children.sorted(by: { naturalCompare($0.lastPathComponent, $1.lastPathComponent) }) {
      let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        if let classified = classifyLocalDir(child, libraryKey: root.path) {
          dirs.append((child.lastPathComponent, classified))
        } else {
          dirs.append((child.lastPathComponent, nil))
          errors.append("无法读取文件夹：\(child.lastPathComponent)")
          isComplete = false
        }
      } else if MediaSniff.isArchive(child.lastPathComponent) || MediaSniff.isPDF(child.lastPathComponent) {
        if let s = scanSingleFile(child, libraryKey: root.path) {
          archiveSeries.append(s)
          archiveChapters.append(s.chapters[0])
        } else {
          errors.append("无法读取：\(child.lastPathComponent)")
          isComplete = false
        }
      }
      // 其他类型文件忽略
    }
    return assembleLibrary(
      dirs: dirs, archiveChapters: archiveChapters, archiveSeries: archiveSeries,
      libraryKey: root.path, libraryName: root.lastPathComponent,
      layout: layout, errors: errors, isComplete: isComplete
    )
  }

  /// 根子目录拆解：三种布局形状（volume=直接装图/包、wrapper=子目录全是卷、series=话/包混装）
  /// 都由 scanSeriesFolderResult 统一拆出「系列 + 章节」——multi 布局下每个子目录仍是一部漫画
  /// （直装图片的文件夹 = 单章节系列），single 布局则复用其章节做整库合并。
  private static func classifyLocalDir(_ folder: URL, libraryKey: String) -> ClassifiedChild? {
    switch scanSeriesFolderResult(folder, libraryKey: libraryKey) {
    case .series(let scanned):
      return ClassifiedChild(kind: "series", series: scanned, chapters: scanned.chapters)
    case .empty:
      return ClassifiedChild(kind: "series", series: nil, chapters: [])
    case .unreadable:
      return nil
    }
  }

  /// 按布局装配扫描结果（三种扫描器共用）：
  /// multi = 每个子目录一部漫画（散包各成单文件系列）；
  /// single = 整库一部漫画（子目录卷/话、卷壳展开、根散包全部合并成章节）。
  static func assembleLibrary(
    dirs: [(name: String, child: ClassifiedChild?)],
    archiveChapters: [ScannedChapter],
    archiveSeries: [ScannedSeries],
    libraryKey: String,
    libraryName: String,
    layout: LibraryScanLayout,
    errors: [String],
    isComplete: Bool
  ) -> ScanReport {
    var errors = errors
    if layout == .single {
      var chapters = archiveChapters
      for dir in dirs {
        guard let child = dir.child else { continue } // 读取失败的目录调用方已报错
        chapters += child.series?.chapters ?? child.chapters
      }
      if !chapters.isEmpty {
        return ScanReport(
          series: [ScannedSeries(key: libraryKey, title: libraryName, chapters: sortChapters(chapters))],
          errors: errors, isComplete: isComplete
        )
      }
      return ScanReport(series: [], errors: errors, isComplete: isComplete)
    }

    var series = archiveSeries
    for dir in dirs {
      guard let child = dir.child else { continue }
      if let scanned = child.series {
        series.append(scanned)
      } else {
        errors.append("目录无内容：\(dir.name)")
      }
    }
    return ScanReport(series: series, errors: errors, isComplete: isComplete)
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

  enum SeriesScanResult {
    case series(ScannedSeries)
    case empty
    /// 有子目录/文件无法读取；结果不完整，调用方必须保留旧数据。
    case unreadable(String)
  }

  /// 一个系列文件夹 → 系列与它的章节
  static func scanSeriesFolderResult(_ folder: URL, libraryKey: String) -> SeriesScanResult {
    let fm = FileManager.default
    guard let children = try? fm.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
    ) else { return .unreadable(folder.lastPathComponent) }

    var chapters: [ScannedChapter] = []
    var looseImages = 0
    var unreadableChild: String?

    for child in children {
      let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDir {
        guard let inner = try? fm.contentsOfDirectory(
          at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
          unreadableChild = child.lastPathComponent
          continue
        }
        let images = inner.filter { MediaSniff.isImage($0.lastPathComponent) }
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

    // 纯散图系列：整个文件夹就是一话；散图与章节共存时，明显的散图内容（≥3 张）也补一章，
    // 零星几张贴图（如封面）不补，避免垃圾章节
    if looseImages > 0 && (chapters.isEmpty || looseImages >= 3) {
      chapters.append(makeChapter(url: folder, kind: "folder", pages: looseImages))
    }

    if let unreadableChild {
      return .unreadable("\(folder.lastPathComponent)/\(unreadableChild)")
    }
    guard !chapters.isEmpty else { return .empty }

    return .series(
      ScannedSeries(
        key: "\(libraryKey)/\(folder.lastPathComponent)",
        title: folder.lastPathComponent,
        chapters: sortChapters(chapters)
      )
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
