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

  // MARK: - WebDAV

  /// 库对应的 WebDAV 客户端（密码从 Keychain 取）
  func webdavClient(forLibrary library: LibraryEntity) -> WebDAVClient? {
    guard library.kind == "webdav", let baseURL = URL(string: String(library.key.dropFirst("webdav:".count))) else {
      return nil
    }
    let password = Keychain.get(account: library.key)
    return WebDAVClient(baseURL: baseURL, username: library.username, password: password)
  }

  // MARK: - 天翼云盘

  private static let cloud189Shared = Cloud189Client()

  /// 全局共享的天翼客户端（会话在 Keychain，登录由 Cloud189LoginView 完成）
  var cloud189Client: Cloud189Client { Self.cloud189Shared }

  func cloud189Client(forLibrary library: LibraryEntity) -> Cloud189Client? {
    guard library.kind == "cloud189" else { return nil }
    let client = Self.cloud189Shared
    client.familyId = library.remoteFamilyId
    return client
  }

  /// 挂载天翼云盘目录为书库（须已登录）
  func addCloud189Library(folderId: String, familyId: String?, name: String) async -> Result<LibraryEntity, Failure> {
    let client = Self.cloud189Shared
    guard client.isLoggedIn else {
      return .failure(Failure("天翼云盘未登录"))
    }
    let context = container.mainContext
    let key = "cloud189:\(familyId.map { "f\($0)" } ?? "p")/\(folderId)"
    let descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { $0.key == key })
    let library = (try? context.fetch(descriptor).first) ?? {
      let lib = LibraryEntity(key: key, name: name, kind: "cloud189")
      context.insert(lib)
      return lib
    }()
    library.name = name
    library.remoteFolderId = folderId
    library.remoteFamilyId = familyId
    library.username = client.session?.loginName
    try? context.save()

    await rescan(library)
    return .success(library)
  }

  /// 连接并挂载 WebDAV 目录为书库
  func addWebDAVLibrary(baseURL: URL, username: String?, password: String?) async -> Result<LibraryEntity, Failure> {
    let probe = WebDAVClient(baseURL: baseURL, username: username, password: password)
    do {
      try await probe.verify()
    } catch {
      return .failure(Failure(error.localizedDescription))
    }

    let context = container.mainContext
    let key = "webdav:" + baseURL.absoluteString
    if let password { Keychain.set(password, account: key) }

    let descriptor = FetchDescriptor<LibraryEntity>(predicate: #Predicate { $0.key == key })
    let library = (try? context.fetch(descriptor).first) ?? {
      let name = baseURL.lastPathComponent.isEmpty ? (baseURL.host ?? "WebDAV") : baseURL.lastPathComponent
      let lib = LibraryEntity(key: key, name: name, kind: "webdav")
      context.insert(lib)
      return lib
    }()
    library.username = username
    try? context.save()

    await rescan(library)
    return .success(library)
  }

  // MARK: - 离线预取

  /// 系列离线缓存进度（seriesKey → 0...1）
  var prefetchProgress: [String: Double] = [:]
  private var prefetchTasks: [String: Task<Void, Never>] = [:]

  func togglePrefetch(_ series: SeriesEntity) {
    if let running = prefetchTasks[series.key] {
      running.cancel()
      prefetchTasks[series.key] = nil
      prefetchProgress[series.key] = nil
      return
    }
    guard let library = series.library else { return }
    let seriesKey = series.key
    let entities = Queries.orderedChapters(series)
    let chapters = entities.map { ch in (path: ch.path, kind: ch.kind, size: ch.fileSize) }
    let count = chapters.count
    guard count > 0 else { return }

    // 各库的下载通道
    let webdav: WebDAVClient? = library.kind == "webdav" ? webdavClient(forLibrary: library) : nil
    let cloud189: Cloud189Client? = library.kind == "cloud189" ? cloud189Client(forLibrary: library) : nil
    guard webdav != nil || cloud189 != nil else { return }

    prefetchProgress[seriesKey] = 0
    let task = Task { [weak self] in
      var done = 0
      var failed = 0
      for chapter in chapters {
        if Task.isCancelled { break }
        do {
          if chapter.path.hasPrefix("cloud189://") {
            guard let client = cloud189, let parsed = Cloud189Path.parse(chapter.path) else {
              failed += 1; continue
            }
            if chapter.kind == "folder" {
              if let remote = await Cloud189FolderPageSource(
                client: client, folderId: parsed.fileId, familyId: parsed.familyId, seriesKey: seriesKey
              ) {
                await remote.prefetchAll()
              }
            } else {
              _ = try await WebDAVCache.shared.ensureChapter(
                stableKey: chapter.path, ext: chapter.kind == "pdf" ? "pdf" : "zip", seriesKey: seriesKey,
                downloader: { dest in
                  try await client.download(fileId: parsed.fileId, familyId: parsed.familyId, to: dest)
                }
              )
            }
          } else if let url = URL(string: chapter.path), let client = webdav {
            if chapter.kind == "folder" {
              if let remote = await RemoteFolderPageSource(client: client, folderURL: url, seriesKey: seriesKey) {
                await remote.prefetchAll()
              }
            } else {
              _ = try await WebDAVCache.shared.ensureChapter(url: url, seriesKey: seriesKey, client: client)
            }
          } else {
            failed += 1
          }
        } catch {
          failed += 1
        }
        done += 1
        self?.prefetchProgress[seriesKey] = Double(done) / Double(count)
      }
      if !Task.isCancelled && failed == 0 {
        var pinned = WebDAVCache.shared.pinnedSeries
        pinned.insert(seriesKey)
        WebDAVCache.shared.pinnedSeries = pinned
      }
      self?.prefetchProgress[seriesKey] = nil
      self?.prefetchTasks[seriesKey] = nil
    }
    prefetchTasks[series.key] = task
  }

  // MARK: - 重扫

  func rescan(_ library: LibraryEntity) async {
    guard !isScanning else { return }
    isScanning = true
    defer { isScanning = false }

    if library.kind == "cloud189" {
      guard let client = cloud189Client(forLibrary: library),
            let folderId = library.remoteFolderId
      else {
        lastErrors = ["天翼云盘配置无效：\(library.name)"]
        return
      }
      let report = await Cloud189Scanner.scanLibrary(
        client: client, rootFolderId: folderId, familyId: library.remoteFamilyId, libraryKey: library.key
      )
      apply(report: report, to: library)
      lastErrors = report.errors
      await generateMissingCovers(for: library, root: nil, cloud189Client: client)
      return
    }

    if library.kind == "webdav" {
      guard let client = webdavClient(forLibrary: library),
            let root = URL(string: String(library.key.dropFirst("webdav:".count)))
      else {
        lastErrors = ["WebDAV 配置无效：\(library.name)"]
        return
      }
      let report = await WebDAVScanner.scanLibrary(client: client, root: root, libraryKey: library.key)
      apply(report: report, to: library)
      lastErrors = report.errors
      await generateMissingCovers(for: library, root: nil, webdavClient: client)
      return
    }

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

  private func generateMissingCovers(
    for library: LibraryEntity, root: URL?,
    webdavClient: WebDAVClient? = nil, cloud189Client: Cloud189Client? = nil
  ) async {
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
      // 云端 zip/PDF 封面要下载整包，超过 40MB 放弃（阅读时会自然缓存）
      if first.kind != "folder" {
        if cloud189Client != nil {
          if first.fileSize > 40 * 1024 * 1024 { continue }
        } else if let webdavClient,
                  let url = URL(string: first.path),
                  let length = await webdavClient.contentLength(url), length > 40 * 1024 * 1024 {
          continue
        }
      }
      jobs.append(CoverJob(seriesKey: series.key, chapterPath: first.path, kind: first.kind))
    }
    guard !jobs.isEmpty else { return }
    let done = await Task.detached(priority: .utility) { [jobs, root, webdavClient, cloud189Client] in
      var count = 0
      for job in jobs {
        if await CoverStore.shared.generate(
          seriesKey: job.seriesKey, chapterPath: job.chapterPath, kind: job.kind,
          libraryRoot: root, webdavClient: webdavClient, cloud189Client: cloud189Client
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
    if library.kind == "webdav" {
      Keychain.remove(account: library.key)
      WebDAVCache.shared.removeLibrary(prefix: library.key)
    }
    if library.kind == "cloud189" {
      WebDAVCache.shared.removeLibrary(prefix: library.key)
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
