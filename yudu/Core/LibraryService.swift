import Foundation
import SwiftData
import Observation

/// 书库编排：添加/导入/重扫/移除，扫描在后台跑、结果回主线程落库
@MainActor
@Observable
final class LibraryService {

  var isScanning = false
  var lastErrors: [String] = []
  /// 封面批量生成完成后递增，驱动界面重载封面
  var coverVersion = 0

  private let container: ModelContainer

  init(container: ModelContainer) {
    self.container = container
  }

  var modelContext: ModelContext { container.mainContext }

  // MARK: - 路径

  private var importsRoot: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let root = support.appendingPathComponent("Yudu/Imports", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  // MARK: - 添加授权文件夹书库

  func addFolderLibrary(url: URL) async -> Result<LibraryEntity, Failure> {
    let context = container.mainContext
    let didAccess = url.startAccessingSecurityScopedResource()
    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

    let bookmark: Data?
    do {
      bookmark = try url.bookmarkData()
    } catch {
      return .failure(Failure("无法保存文件夹访问权限：\(error.localizedDescription)"))
    }

    let key = url.path
    let descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { $0.key == key })
    let library = (try? context.fetch(descriptor).first) ?? {
      let lib = LibraryEntity(key: key, name: url.lastPathComponent, kind: "folder", bookmark: bookmark)
      context.insert(lib)
      return lib
    }()
    library.bookmark = bookmark
    try? context.save()

    await rescan(library)
    return .success(library)
  }

  // MARK: - 导入文件

  /// 把选中的 zip/cbz/pdf 拷进沙盒，每个文件独立目录（避免同名冲突）
  func importFiles(urls: [URL]) async -> Result<Int, Failure> {
    guard !urls.isEmpty else { return .success(0) }
    let context = container.mainContext

    var copied = 0
    var failures: [String] = []
    for source in urls {
      let didAccess = source.startAccessingSecurityScopedResource()
      defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

      let ext = MediaSniff.extensionOf(source.lastPathComponent)
      let stem = sanitizeFilename(MediaSniff.stemOf(source.lastPathComponent))
      let dirName = "\(stem)-\(UUID().uuidString.prefix(8))"
      let destDir = importsRoot.appendingPathComponent(dirName, isDirectory: true)
      let dest = destDir.appendingPathComponent("volume.\(ext)")
      do {
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
          if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
          }
          try FileManager.default.copyItem(at: source, to: dest)
          copied += 1
        } catch {
          failures.append("导入 \(source.lastPathComponent) 失败：\(error.localizedDescription)")
        }
    }

    let library = ensureImportsLibrary()
    try? context.save()
    await rescan(library)
    if copied == 0, let first = failures.first {
      return .failure(Failure(first))
    }
    lastErrors = failures
    return .success(copied)
  }

  private func ensureImportsLibrary() -> LibraryEntity {
    let context = container.mainContext
    let key = "imports"
    let descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { $0.key == key })
    if let existing = try? context.fetch(descriptor).first { return existing }
    let lib = LibraryEntity(key: key, name: "导入", kind: "imports", bookmark: nil)
    context.insert(lib)
    return lib
  }

  // MARK: - 重扫

  func rescan(_ library: LibraryEntity) async {
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }

    let root: URL?
    if library.kind == "folder" {
      root = resolveRoot(library)
      guard root != nil else {
        lastErrors = ["无法恢复文件夹访问权限：\(library.name)"]
        return
      }
    } else {
      root = importsRoot
    }

    // 扫描是同步重活，丢到后台执行器
    let report: ScanReport = await Task.detached(priority: .userInitiated) { [root] in
      guard let root else { return ScanReport(series: [], errors: ["书库路径无效"]) }
      return LibraryScanner.scanLibraryRoot(root: root)
    }.value

    apply(report: report, to: library)
    lastErrors = report.errors

    // 补封面（只给还没有封面的系列）
    await generateMissingCovers(for: library, root: root)
  }

  func rescanAll() async {
    let context = container.mainContext
    let descriptor = FetchDescriptor<LibraryEntity>()
    let libraries = (try? context.fetch(descriptor)) ?? []
    for library in libraries {
      await rescan(library)
    }
  }

  /// App 启动时静默重扫（文件夹库权限可能失效，失败不弹窗）
  func rescanOnLaunch() async {
    let context = container.mainContext
    let descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { $0.kind == "folder" })
    let libraries = (try? context.fetch(descriptor)) ?? []
    for library in libraries {
      await rescan(library)
    }
  }

  private func apply(report: ScanReport, to library: LibraryEntity) {
    let context = container.mainContext
    let scannedKeys = Set(report.series.map(\.key))

    // 全量章节索引（按 path 去重匹配）
    let allChapters = (try? context.fetch(FetchDescriptor<ChapterEntity>())) ?? []
    var chapterByPath: [String: ChapterEntity] = [:]
    for ch in allChapters { chapterByPath[ch.path] = ch }

    for scanned in report.series {
      let series: SeriesEntity
      if let existing = library.series.first(where: { $0.key == scanned.key }) {
        series = existing
      } else {
        series = SeriesEntity(key: scanned.key, title: scanned.title)
        series.library = library
        context.insert(series)
      }
      series.title = scanned.title

      let scannedPaths = Set(scanned.chapters.map(\.path))
      for (index, scannedChapter) in scanned.chapters.enumerated() {
        let chapter = chapterByPath[scannedChapter.path] ?? {
          let ch = ChapterEntity(path: scannedChapter.path, title: scannedChapter.title)
          ch.series = series
          context.insert(ch)
          chapterByPath[scannedChapter.path] = ch
          return ch
        }()
        chapter.series = series
        chapter.title = scannedChapter.title
        chapter.volume = scannedChapter.volume
        chapter.number = scannedChapter.number
        chapter.sortIndex = index
        chapter.kind = scannedChapter.kind
        chapter.pageCount = scannedChapter.pageCount
        chapter.fileSize = scannedChapter.size
        chapter.modifiedAt = scannedChapter.mtime
      }

      // 删掉本系列下已消失的章节（级联删进度）
      for chapter in series.chapters where !scannedPaths.contains(chapter.path) {
        context.delete(chapter)
      }
    }

    // 删掉本次没扫到的系列
    for series in library.series where !scannedKeys.contains(series.key) {
      CoverStore.shared.remove(seriesKey: series.key)
      context.delete(series)
    }

    try? context.save()
  }

  private func generateMissingCovers(for library: LibraryEntity, root: URL?) async {
    struct CoverJob {
      let seriesKey: String
      let chapterPath: String
      let kind: String
    }
    var jobs: [CoverJob] = []
    for series in library.series {
      guard !CoverStore.shared.hasCover(seriesKey: series.key) else { continue }
      let first = Queries.orderedChapters(series).first
      guard let first else { continue }
      jobs.append(CoverJob(seriesKey: series.key, chapterPath: first.path, kind: first.kind))
    }
    guard !jobs.isEmpty else { return }
    let done = await Task.detached(priority: .utility) { [jobs, root] in
      var count = 0
      for job in jobs {
        if await CoverStore.shared.generate(
          seriesKey: job.seriesKey, chapterPath: job.chapterPath, kind: job.kind, libraryRoot: root
        ) {
          count += 1
        }
      }
      return count
    }.value
    if done > 0 { coverVersion += 1 }
  }

  // MARK: - 移除

  func removeLibrary(_ library: LibraryEntity) {
    let context = container.mainContext
    if library.kind == "imports" {
      try? FileManager.default.removeItem(at: importsRoot)
    }
    for series in library.series {
      CoverStore.shared.remove(seriesKey: series.key)
    }
    context.delete(library)
    try? context.save()
  }

  /// 删除单个导入系列（连同拷贝进来的文件）
  func removeImportedSeries(_ series: SeriesEntity) {
    let context = container.mainContext
    let prefix = series.key.hasPrefix("imports/") ? String(series.key.dropFirst("imports/".count)) : nil
    if let prefix {
      let dir = importsRoot.appendingPathComponent(prefix, isDirectory: true)
      try? FileManager.default.removeItem(at: dir)
    }
    CoverStore.shared.remove(seriesKey: series.key)
    context.delete(series)
    try? context.save()
  }

  // MARK: - 书签恢复

  func resolveRoot(_ library: LibraryEntity) -> URL? {
    guard let data = library.bookmark else { return nil }
    var stale = false
    guard let url = try? URL(
      resolvingBookmarkData: data,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale
    ) else { return nil }
    if stale {
      library.bookmark = try? url.bookmarkData()
      try? container.mainContext.save()
    }
    return url
  }

  /// 阅读器用：给定章节所在系列，返回其书库根目录（授权文件夹需要 scope）
  func libraryRoot(for series: SeriesEntity) -> URL? {
    guard let library = series.library, library.kind == "folder" else { return nil }
    return resolveRoot(library)
  }

  private func sanitizeFilename(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
    let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "未命名" : String(cleaned.prefix(60))
  }
}
