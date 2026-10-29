import Foundation
import SwiftData
import Observation

/// 书库编排：添加/导入/重扫/移除，扫描在后台跑、结果回主线程落库
@MainActor
@Observable
final class LibraryService {

  var isScanning = false
  var lastErrors: [String] = []
  /// 最近一次扫描的结果摘要（增量/完整、新增数量），给界面一个明确反馈
  var lastScanSummary: String?
  /// 当前扫描进度（云端扫描逐目录/逐章更新），nil 表示无细分进度
  var scanProgress: ScanProgressInfo?

  struct ScanProgressInfo {
    var current: Int
    var total: Int
    var title: String
  }
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
    let root = importsRoot

    // 大文件拷贝不能占着主线程；安全作用域访问在后台线程同样有效。
    let outcome = await Task.detached(priority: .userInitiated) { () -> (copied: Int, failures: [String]) in
      var copied = 0
      var failures: [String] = []
      for source in urls {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }

        let originalName = source.lastPathComponent
        let ext = MediaSniff.extensionOf(originalName)
        let stem = Self.sanitizeFilename(MediaSniff.stemOf(originalName))
        let dirName = "\(stem)-\(UUID().uuidString.prefix(8))"
        let destDir = root.appendingPathComponent(dirName, isDirectory: true)
        // 保留原文件名：扫描器会用它作为章节/系列标题，而不是 "volume"。
        let fileName = ext.isEmpty ? stem : "\(stem).\(ext)"
        let dest = destDir.appendingPathComponent(fileName)
        do {
          try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
          if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
          }
          try FileManager.default.copyItem(at: source, to: dest)
          copied += 1
        } catch {
          failures.append("导入 \(originalName) 失败：\(error.localizedDescription)")
        }
      }
      return (copied, failures)
    }.value

    let library = ensureImportsLibrary()
    try? context.save()
    await rescan(library)
    if outcome.copied == 0, let first = outcome.failures.first {
      return .failure(Failure(first))
    }
    lastErrors = outcome.failures
    return .success(outcome.copied)
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
    return Self.cloud189Shared
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

    // 首次扫描放后台：云盘目录按协议节流逐页遍历，可能要几分钟，不能卡住挂载界面
    scanInBackground(library)
    return .success(library)
  }

  /// 后台完成首次扫描（rescan 遇忙直接返回，这里等它空闲再扫）
  private func scanInBackground(_ library: LibraryEntity) {
    Task {
      while isScanning {
        try? await Task.sleep(for: .seconds(0.5))
      }
      await rescan(library)
    }
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

    scanInBackground(library)
    return .success(library)
  }

  // MARK: - 离线预取

  /// 系列离线缓存进度（seriesKey → 0...1）
  var prefetchProgress: [String: Double] = [:]
  var prefetchErrors: [String: String] = [:]
  private var prefetchTasks: [String: Task<Void, Never>] = [:]

  func togglePrefetch(_ series: SeriesEntity) {
    if let running = prefetchTasks[series.key] {
      running.cancel()
      return
    }
    guard let library = series.library else { return }
    let seriesKey = series.key
    let entities = Queries.orderedChapters(series)
    let chapters = entities.map { ch in
      (
        path: ch.path,
        kind: ch.kind,
        size: ch.fileSize,
        version: "\(ch.path)#\(Int(ch.modifiedAt.timeIntervalSince1970))#\(ch.fileSize)"
      )
    }
    let count = chapters.count
    guard count > 0 else { return }

    // 各库的下载通道
    let webdav: WebDAVClient? = library.kind == "webdav" ? webdavClient(forLibrary: library) : nil
    let cloud189: Cloud189Client? = library.kind == "cloud189" ? cloud189Client(forLibrary: library) : nil
    guard webdav != nil || cloud189 != nil else { return }

    prefetchErrors[seriesKey] = nil
    prefetchProgress[seriesKey] = 0
    // 手动离线期间保护该系列，否则容量清理会在下载过程中把刚缓存的章节删掉。
    WebDAVCache.shared.protect(seriesKey: seriesKey)
    let task = Task { [weak self] in
      defer {
        WebDAVCache.shared.unprotect(seriesKey: seriesKey)
        self?.prefetchProgress[seriesKey] = nil
        self?.prefetchTasks[seriesKey] = nil
      }
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
                if !(await remote.prefetchAll()) { failed += 1 }
              } else { failed += 1 }
            } else {
              _ = try await WebDAVCache.shared.ensureChapter(
                stableKey: chapter.path, ext: chapter.kind == "pdf" ? "pdf" : "zip", seriesKey: seriesKey,
                version: chapter.version,
                downloader: { dest in
                  try await client.download(fileId: parsed.fileId, familyId: parsed.familyId, to: dest)
                }
              )
            }
          } else if let url = URL(string: chapter.path), let client = webdav {
            if chapter.kind == "folder" {
              if let remote = await RemoteFolderPageSource(client: client, folderURL: url, seriesKey: seriesKey) {
                if !(await remote.prefetchAll()) { failed += 1 }
              } else { failed += 1 }
            } else {
              _ = try await WebDAVCache.shared.ensureChapter(
                url: url, seriesKey: seriesKey, client: client, version: chapter.version
              )
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
      if !Task.isCancelled && failed > 0 {
        self?.prefetchErrors[seriesKey] = "有 \(failed) 个章节未能缓存，请检查网络后重试。"
      }
    }
    prefetchTasks[series.key] = task
  }

  // MARK: - 重扫

  func rescan(_ library: LibraryEntity, mode: LibraryScanMode = .incremental) async {
    guard !isScanning else { return }
    isScanning = true
    lastScanSummary = nil
    defer {
      isScanning = false
      scanProgress = nil
      ScanLiveActivity.finish()
    }

    if library.kind == "cloud189" {
      guard let client = cloud189Client(forLibrary: library),
            let folderId = library.remoteFolderId
      else {
        lastErrors = ["天翼云盘配置无效：\(library.name)"]
        return
      }
      ScanLiveActivity.begin(libraryName: library.name)
      let report = await Cloud189Scanner.scanLibrary(
        client: client, rootFolderId: folderId, familyId: library.remoteFamilyId,
        libraryKey: library.key, libraryName: library.name, mode: mode
      ) { current, total, title in
        Task { @MainActor in
          self.scanProgress = ScanProgressInfo(current: current, total: total, title: title)
          ScanLiveActivity.update(current: current, total: total, title: title)
        }
      }
      apply(report: report, to: library, mode: mode)
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
      ScanLiveActivity.begin(libraryName: library.name)
      let report = await WebDAVScanner.scanLibrary(client: client, root: root, libraryKey: library.key, mode: mode)
      apply(report: report, to: library, mode: mode)
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

    // 授权文件夹必须在扫描期间持有安全作用域；拿不到就保留旧数据并报错。
    var access: LibraryAccess.AutoClose?
    if library.kind == "folder", let root {
      guard let token = LibraryAccess.shared.begin(url: root) else {
        lastErrors = ["无法恢复文件夹访问权限：\(library.name)"]
        return
      }
      access = token
    }
    defer { access?.release() }

    // 扫描是同步重活，丢到后台执行器
    let report: ScanReport = await Task.detached(priority: .userInitiated) { [root] in
      guard let root else { return ScanReport(series: [], errors: ["书库路径无效"], isComplete: false) }
      return LibraryScanner.scanLibraryRoot(root: root)
    }.value

    apply(report: report, to: library, mode: mode)
    lastErrors = report.errors

    // 补封面（只给还没有封面的系列）
    await generateMissingCovers(for: library, root: root)
  }

  func rescanAll(mode: LibraryScanMode = .incremental) async {
    guard !isScanning else { return }
    let context = container.mainContext
    let descriptor = FetchDescriptor<LibraryEntity>()
    let libraries = (try? context.fetch(descriptor)) ?? []
    var errors: [String] = []
    for library in libraries {
      await rescan(library, mode: mode)
      errors += lastErrors.map { "\(library.name)：\($0)" }
    }
    lastErrors = errors
    if libraries.isEmpty {
      lastScanSummary = "还没有可扫描的书库"
    } else {
      lastScanSummary = "\(mode.label)扫描完成：共 \(libraries.count) 个来源"
    }
  }

  private func apply(report: ScanReport, to library: LibraryEntity, mode: LibraryScanMode) {
    let previousSeriesKeys = Set(library.series.map(\.key))
    let previousChapterPaths = Set(library.series.flatMap { $0.chapters.map(\.path) })
    applyReport(report: report, to: library)
    let currentSeriesKeys = Set(report.series.map(\.key))
    let currentChapterPaths = Set(report.series.flatMap { $0.chapters.map(\.path) })
    let addedSeries = currentSeriesKeys.subtracting(previousSeriesKeys).count
    let removedSeries = report.isComplete ? previousSeriesKeys.subtracting(currentSeriesKeys).count : 0
    let addedChapters = currentChapterPaths.subtracting(previousChapterPaths).count
    let removedChapters = report.isComplete ? previousChapterPaths.subtracting(currentChapterPaths).count : 0

    var parts: [String] = []
    if addedSeries > 0 { parts.append("新增 \(addedSeries) 部") }
    if removedSeries > 0 { parts.append("移除 \(removedSeries) 部") }
    if addedChapters > 0 { parts.append("新增 \(addedChapters) 话") }
    if removedChapters > 0 { parts.append("移除 \(removedChapters) 话") }
    if !report.isComplete { parts.append("部分目录未读取") }
    if parts.isEmpty { parts.append("没有发现新内容") }
    let title = (library.kind == "folder" || library.kind == "imports")
      ? "扫描完成"
      : "\(mode.label)扫描完成"
    lastScanSummary = title + "：" + parts.joined(separator: "，")
  }

  private func applyReport(report: ScanReport, to library: LibraryEntity) {
    let context = container.mainContext
    let scannedKeys = Set(report.series.map(\.key))

    // 全量章节索引（按 path 去重匹配）
    let allChapters = (try? context.fetch(FetchDescriptor<ChapterEntity>())) ?? []
    var chapterByPath: [String: ChapterEntity] = [:]
    for ch in allChapters { chapterByPath[ch.path] = ch }

    for scanned in report.series {
      let displayTitle = library.kind == "imports"
        ? Self.importedDisplayTitle(scanned.title)
        : scanned.title
      let series: SeriesEntity
      if let existing = library.series.first(where: { $0.key == scanned.key }) {
        series = existing
      } else {
        series = SeriesEntity(key: scanned.key, title: displayTitle)
        series.library = library
        context.insert(series)
      }
      series.title = displayTitle

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
        // 兼容旧版导入：文件名被改成了 volume.zip，用系列标题兜底。
        chapter.title = library.kind == "imports" && scannedChapter.title == "volume"
          ? displayTitle
          : scannedChapter.title
        chapter.volume = scannedChapter.volume
        chapter.number = scannedChapter.number
        chapter.sortIndex = index
        chapter.kind = scannedChapter.kind
        // 云端扫描拿不到页数（0 = 未知），不能用 0 覆盖已经回填过的真实页数。
        if scannedChapter.pageCount > 0 || chapter.pageCount <= 0 {
          chapter.pageCount = scannedChapter.pageCount
        }
        chapter.fileSize = scannedChapter.size
        chapter.modifiedAt = scannedChapter.mtime
      }

      // 删掉本系列下已消失的章节（级联删进度）
      if report.isComplete {
        for chapter in series.chapters where !scannedPaths.contains(chapter.path) {
          context.delete(chapter)
        }
      }
    }

    // 删掉本次没扫到的系列。扫描不完整时只更新、不删除，避免一次网络/权限失败清空书库。
    if report.isComplete {
      for series in library.series where !scannedKeys.contains(series.key) {
        CoverStore.shared.remove(seriesKey: series.key)
        context.delete(series)
      }
    }

    try? context.save()
  }

  /// 导入目录名形如 "书名-AB12CD34"；展示时去掉随机后缀。
  nonisolated static func importedDisplayTitle(_ folderName: String) -> String {
    let stripped = folderName.replacingOccurrences(
      of: #"-[0-9A-Fa-f]{8}$"#, with: "", options: .regularExpression
    )
    return stripped.isEmpty ? folderName : stripped
  }

  private func generateMissingCovers(
    for library: LibraryEntity, root: URL?,
    webdavClient: WebDAVClient? = nil, cloud189Client: Cloud189Client? = nil
  ) async {
    struct CoverJob {
      let seriesKey: String
      let chapterPath: String
      let kind: String
      let modifiedAt: Date
      let version: String
    }
    var jobs: [CoverJob] = []
    for series in library.series {
      let first = Queries.orderedChapters(series).first
      guard let first else { continue }
      guard !CoverStore.shared.isFresh(seriesKey: series.key, sourceModifiedAt: first.modifiedAt) else {
        continue
      }
      // 远程 zip 只取中央目录 + 首页；PDF 只能整包下载，超过 40MB 就放弃。
      if first.kind == "pdf" {
        if cloud189Client != nil {
          if first.fileSize > 40 * 1024 * 1024 { continue }
        } else if let webdavClient,
                  let url = URL(string: first.path),
                  let length = await webdavClient.contentLength(url), length > 40 * 1024 * 1024 {
          continue
        }
      }
      jobs.append(
        CoverJob(
          seriesKey: series.key,
          chapterPath: first.path,
          kind: first.kind,
          modifiedAt: first.modifiedAt,
          version: "\(first.path)#\(Int(first.modifiedAt.timeIntervalSince1970))#\(first.fileSize)"
        )
      )
    }
    guard !jobs.isEmpty else { return }
    let done = await Task.detached(priority: .utility) { [jobs, root, webdavClient, cloud189Client] in
      var count = 0
      // 封面最多 3 个并发，避免大量远端请求同时排队；阅读时让路。
      for start in stride(from: 0, to: jobs.count, by: 3) {
        await ReaderActivity.waitWhileReading()
        let chunk = Array(jobs[start..<min(start + 3, jobs.count)])
        let partial = await withTaskGroup(of: Bool.self) { group -> Int in
          for job in chunk {
            group.addTask {
              await CoverStore.shared.generate(
                seriesKey: job.seriesKey, chapterPath: job.chapterPath, kind: job.kind,
                libraryRoot: root, webdavClient: webdavClient, cloud189Client: cloud189Client,
                contentVersion: job.version
              )
            }
          }
          var success = 0
          for await ok in group where ok { success += 1 }
          return success
        }
        count += partial
      }
      return count
    }.value
    if done > 0 { coverVersion += 1 }
  }

  // MARK: - 移除

  func removeLibrary(_ library: LibraryEntity) {
    let context = container.mainContext
    ScanCache.clear(libraryKey: library.key)
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
      prefetchTasks[series.key]?.cancel()
      prefetchErrors[series.key] = nil
      CoverStore.shared.remove(seriesKey: series.key)
    }
    context.delete(library)
    try? context.save()
  }

  /// 删除单个导入系列（连同拷贝进来的文件）
  func removeImportedSeries(_ series: SeriesEntity) {
    let context = container.mainContext
    if series.library?.kind == "imports" {
      let root = importsRoot.standardizedFileURL
      let candidate: URL
      if series.key.hasPrefix("imports/") {
        candidate = root.appendingPathComponent(String(series.key.dropFirst("imports/".count)), isDirectory: true)
      } else {
        // 旧版导入的 key 是绝对路径。
        candidate = URL(fileURLWithPath: series.key, isDirectory: true)
      }
      let dir = candidate.standardizedFileURL
      if dir.path.hasPrefix(root.path + "/") {
        try? FileManager.default.removeItem(at: dir)
      }
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

  nonisolated private static func sanitizeFilename(_ name: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
    let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? "未命名" : String(cleaned.prefix(60))
  }
}
