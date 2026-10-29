import SwiftUI
import SwiftData
import Observation

/// 阅读器状态机：当前话、页码、偏好、跨话连读、进度落库
@MainActor
@Observable
final class ReaderViewModel {

  // 输入
  private let series: SeriesEntity
  private let context: ModelContext
  private let libraryService: LibraryService

  // 系列
  private(set) var chapters: [ChapterRef] = []
  private(set) var currentIndex: Int = 0
  private(set) var current: ChapterRef?

  // 页源
  private(set) var source: (any PageSource)?
  private var opened: PageSourceFactory.OpenedSource?
  private(set) var sourceID: String = ""
  private(set) var pageCount: Int = 0
  private(set) var page: Int = 0
  private(set) var isLoading = true
  var errorMessage: String?

  // 偏好（系列记忆 + 全局默认）
  private(set) var prefs: EffectivePrefs

  // 界面
  var chromeVisible = true
  var showDirectionHint = false
  /// 条漫页尺寸（渐进加载）
  private(set) var dims: [Int: CGSize] = [:]
  var dimsReadyThrough = -1
  /// 条漫恢复进度中
  var restoringScroll = false

  private var openTask: Task<Void, Never>?
  private var dimsTask: Task<Void, Never>?
  private var dimsSaveTask: Task<Void, Never>?
  private var progressTask: Task<Void, Never>?
  private var prefetchTask: Task<Void, Never>?
  private var hintTask: Task<Void, Never>?
  private var didShowHint = false
  /// init 时按目标章节算好的起始页（0 起；-1 表示落上一话末页）
  private var initialResume = 0
  /// 打开章节期间禁止进度落库，避免把旧页码写进新章节。
  private var isOpenInFlight = false
  /// 每次打开递增；旧的异步打开完成后不能覆盖新章节的状态。
  private var openEpoch = 0
  /// 已发起尺寸探测的页，避免条漫懒加载重复解压同一页。
  private var dimsRequests: Set<Int> = []

  var isPDF: Bool { current?.isPDF ?? false }
  var effectiveMode: ReaderMode { isPDF ? .webtoon : prefs.mode }
  /// 云端页源：预取更保守，尺寸探测只读图头
  var isRemoteSource: Bool { source?.isRemote ?? false }

  var prevChapter: ChapterRef? {
    chapters.indices.contains(currentIndex - 1) ? chapters[currentIndex - 1] : nil
  }

  var nextChapter: ChapterRef? {
    chapters.indices.contains(currentIndex + 1) ? chapters[currentIndex + 1] : nil
  }

  init(series: SeriesEntity, startChapter: ChapterEntity?, context: ModelContext, libraryService: LibraryService) {
    self.series = series
    self.context = context
    self.libraryService = libraryService
    self.prefs = Queries.prefs(for: series)

    let refs = Queries.chaptersRef(series)
    self.chapters = refs
    let target: ChapterEntity?
    if let startChapter {
      target = startChapter
    } else if let cont = Queries.continueTarget(series) {
      target = cont
    } else {
      target = Queries.orderedChapters(series).first
    }
    if let target, let idx = refs.firstIndex(where: { $0.path == target.path }) {
      currentIndex = idx
      initialResume = Queries.resumePage(target)
    }
  }

  func start() {
    openTask?.cancel()
    openTask = Task { await openCurrent(resume: initialResume) }
    if effectiveMode != .webtoon, !didShowHint {
      didShowHint = true
      showDirectionHint = true
      hintTask = Task {
        try? await Task.sleep(for: .seconds(1.8))
        showDirectionHint = false
      }
    }
  }

  func stop() {
    openTask?.cancel()
    dimsTask?.cancel()
    dimsSaveTask?.cancel()
    dimsSaveTask = nil
    progressTask?.cancel()
    prefetchTask?.cancel()
    hintTask?.cancel()
    saveDimsNow()
    flushProgress()
    if let opened {
      opened.access?.release()
    }
    opened = nil
    source = nil
  }

  private func fail(_ message: String) {
    errorMessage = message
    isLoading = false
  }

  private var chapterEntity: ChapterEntity? {
    series.chapters.first { $0.path == current?.path }
  }

  // MARK: - 打开章节

  private func openCurrent(resume: Int) async {
    guard chapters.indices.contains(currentIndex) else {
      fail("没有可读的章节")
      return
    }
    openEpoch += 1
    let epoch = openEpoch
    isOpenInFlight = true
    defer {
      if epoch == openEpoch { isOpenInFlight = false }
    }

    progressTask?.cancel()
    progressTask = nil
    dimsTask?.cancel()
    dimsTask = nil
    prefetchTask?.cancel()
    prefetchTask = nil
    dimsRequests.removeAll()

    let ref = chapters[currentIndex]
    current = ref
    isLoading = true
    errorMessage = nil
    // 先清零：若用户在打开过程中退出，flushProgress 不会把上一话页码写到新章节。
    saveDimsNow()
    dimsSaveTask?.cancel()
    dimsSaveTask = nil
    page = 0
    pageCount = 0
    dims = [:]
    dimsReadyThrough = -1
    restoringScroll = false

    if let opened {
      opened.access?.release()
    }
    opened = nil
    source = nil

    let root = libraryService.libraryRoot(for: series)
    let webdavClient: WebDAVClient? = series.library?.kind == "webdav"
      ? libraryService.webdavClient(forLibrary: series.library!)
      : nil
    let cloud189Client: Cloud189Client? = series.library?.kind == "cloud189" && series.library != nil
      ? libraryService.cloud189Client(forLibrary: series.library!)
      : nil
    let opened = await PageSourceFactory.open(
      chapterPath: ref.path, kind: ref.kind, libraryRoot: root,
      seriesKey: series.key, webdavClient: webdavClient, cloud189Client: cloud189Client,
      contentVersion: ref.cacheVersion
    )
    guard epoch == openEpoch, !Task.isCancelled else {
      opened?.access?.release()
      return
    }
    guard let opened else {
      fail("打不开这一话（文件可能被移动或权限失效）")
      return
    }

    self.opened = opened
    self.source = opened.source
    self.sourceID = ref.cacheVersion
    self.pageCount = max(opened.source.pageCount, 0)
    isLoading = false
    #if DEBUG
    ReaderProbe.lastPageCount = pageCount
    #endif

    // 尺寸持久化：条漫续读/二次打开直接用上次记住的宽高，不再重新探测
    let persistedDims = PageDimsStore.shared.load(sourceID: ref.cacheVersion)
    if !persistedDims.isEmpty {
      dims = persistedDims
      var ready = -1
      while ready + 1 < pageCount, dims[ready + 1] != nil { ready += 1 }
      dimsReadyThrough = ready
    }

    // 页数回填（对齐桌面版 chapter:pageCount）
    if ref.pageCount != pageCount, let entity = chapterEntity {
      entity.pageCount = pageCount
      try? context.save()
      chapters[currentIndex].pageCount = pageCount
    }

    let landing: Int
    if resume >= 0 {
      landing = pageCount > 0 ? min(resume, pageCount - 1) : resume
    } else {
      landing = pageCount > 0 ? pageCount - 1 : 0 // “上一话末页”落地
    }
    setPage(landing, animated: false)

    // 条漫只补目标页附近的尺寸缺口；setPage 已经触发预取，不再重复调用。
    if effectiveMode == .webtoon {
      startDimsProbe(around: landing)
    }

    // 条漫恢复位置：目标页尺寸就绪后滚动（上方缺尺寸时允许近似落位）
    if effectiveMode == .webtoon, landing > 0 {
      restoringScroll = true
    }
  }

  /// 条漫尺寸探测：只补目标页 ±2 的缺口，走专用线程池。
  /// 尺寸会持久化，二次打开基本不再探测；不再把 0...目标页+8 整段探测一遍。
  private func startDimsProbe(around targetPage: Int) {
    dimsTask?.cancel()
    guard let source = self.source, pageCount > 0 else {
      markDimsReady(index: 0)
      return
    }
    let count = pageCount
    let epoch = openEpoch
    let target = min(max(targetPage, 0), count - 1)
    // 目标页尺寸已知就立即允许恢复滚动，不等邻居
    if dims[target] != nil {
      markDimsReady(index: target, epoch: epoch)
    }
    let lower = max(0, target - 2)
    let upper = min(count - 1, target + 2)
    // 目标页优先：拿到它就能恢复滚动，邻居尺寸随后补
    let missing = [target] + (lower...upper).filter { $0 != target && dims[$0] == nil }
    let pending = missing.filter { dims[$0] == nil }
    guard !pending.isEmpty else {
      markDimsReady(index: target, epoch: epoch)
      return
    }
    dimsTask = Task.detached(priority: .utility) { [weak self] in
      for index in pending {
        if Task.isCancelled { return }
        let value = await PageLoadExecutor.shared.run(priority: .utility) {
          source.pageDims(at: index)
        }
        if let value {
          await self?.applyDim(index: index, dims: value, epoch: epoch)
        }
        if index == target {
          await self?.markDimsReady(index: target, epoch: epoch)
        }
      }
      await self?.markDimsReady(index: target, epoch: epoch)
    }
  }

  /// 条漫页项滚到附近时按需取尺寸，不阻塞主线程；远程源只读图头。
  func requestDims(for index: Int) {
    guard index >= 0, index < pageCount, dims[index] == nil,
          !dimsRequests.contains(index), let source = self.source else { return }
    dimsRequests.insert(index)
    let epoch = openEpoch
    Task.detached(priority: .utility) {
      let value = await PageLoadExecutor.shared.run(priority: .utility) {
        source.pageDims(at: index)
      }
      await MainActor.run { [weak self] in
        guard let self, self.openEpoch == epoch else { return }
        self.dimsRequests.remove(index)
        if let value {
          self.dims[index] = value
          self.scheduleDimsSave()
        }
      }
    }
  }

  private func applyDim(index: Int, dims: CGSize, epoch: Int) {
    guard epoch == openEpoch, self.dims[index] == nil else { return }
    self.dims[index] = dims
    scheduleDimsSave()
  }

  /// 页图解码完成后回填尺寸（单页模式也记录，之后切条漫不用再探测）
  func recordPageSize(index: Int, size: CGSize) {
    guard index >= 0, index < pageCount, size.width > 0, size.height > 0 else { return }
    guard dims[index] == nil else { return }
    dims[index] = size
    if index == dimsReadyThrough + 1 {
      dimsReadyThrough = index
    }
    scheduleDimsSave()
  }

  private func scheduleDimsSave() {
    dimsSaveTask?.cancel()
    let sid = sourceID
    guard !sid.isEmpty, !dims.isEmpty else { return }
    let snapshot = dims
    dimsSaveTask = Task.detached(priority: .utility) {
      try? await Task.sleep(for: .seconds(1))
      guard !Task.isCancelled else { return }
      PageDimsStore.shared.save(sourceID: sid, dims: snapshot)
    }
  }

  private func saveDimsNow() {
    guard !sourceID.isEmpty, !dims.isEmpty else { return }
    PageDimsStore.shared.save(sourceID: sourceID, dims: dims)
  }

  private func markDimsReady(index: Int, epoch: Int) {
    guard epoch == openEpoch else { return }
    if index > dimsReadyThrough { dimsReadyThrough = index }
  }

  private func markDimsReady(index: Int) {
    if index > dimsReadyThrough { dimsReadyThrough = index }
  }

  // MARK: - 翻页

  func setPage(_ newPage: Int, animated: Bool = true) {
    let clamped = pageCount > 0 ? min(max(newPage, 0), pageCount - 1) : max(newPage, 0)
    page = clamped
    scheduleProgressWrite()
    prefetch(around: clamped)
  }

  /// 单页模式点按/滑动翻页：越界自动跨话
  func step(_ direction: Int) {
    let target = page + direction
    if pageCount == 0 || target <= pageCount - 1, target >= 0 {
      setPage(target)
    } else if direction > 0, nextChapter != nil {
      Task { await goToChapter(offset: 1, landing: 0) }
    } else if direction < 0, prevChapter != nil {
      Task { await goToChapter(offset: -1, landing: -1) } // 上一话末页
    }
  }

  func goToChapter(offset: Int, landing: Int) async {
    flushProgress()
    let index = currentIndex + offset
    guard chapters.indices.contains(index) else { return }
    openTask?.cancel()
    currentIndex = index
    await openCurrent(resume: landing)
  }

  /// 底栏“上一话”：回到上一话的续读位置，而不是末页。
  /// 末页会被 writeProgress 当成“已读完”，用户只是返回就会被误标完成。
  func goToPreviousChapter() async {
    guard let previous = prevChapter else { return }
    let entity = series.chapters.first { $0.path == previous.path }
    let landing = entity.map { Queries.resumePage($0) } ?? 0
    await goToChapter(offset: -1, landing: landing)
  }

  func jumpToChapter(_ ref: ChapterRef) async {
    guard let index = chapters.firstIndex(where: { $0.path == ref.path }) else { return }
    flushProgress()
    openTask?.cancel()
    currentIndex = index
    let landing = series.chapters.first { $0.path == ref.path }.map { Queries.resumePage($0) } ?? 0
    await openCurrent(resume: landing)
  }

  // MARK: - 预取

  /// 预取策略按源类型区分：
  /// - 云端单页：只提前 1 页，且尺寸与前台一致（命中缓存后不用重下 40MB）
  /// - 本地单页：预取 2048 预览，前台再升级 4096
  /// - 条漫：云端只 1 页，本地前后各 2 页
  /// 顺序始终是「下一页优先」；云端先让当前页下载 250ms。
  private func prefetch(around index: Int) {
    prefetchTask?.cancel()
    guard let source, pageCount > 0 else { return }
    let remote = source.isRemote
    let maxPixel: Int
    let order: [Int]
    if effectiveMode == .webtoon {
      maxPixel = 2048
      order = remote ? [index + 1] : [index + 1, index + 2, index - 1, index - 2]
    } else if remote {
      maxPixel = 4096
      order = [index + 1]
    } else {
      maxPixel = 2048
      order = [index + 1, index + 2, index - 1]
    }
    let indices = order.filter { $0 >= 0 && $0 < pageCount }
    guard !indices.isEmpty else { return }
    let sourceBox = source
    let sid = sourceID
    prefetchTask = Task.detached(priority: .utility) {
      if remote {
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
      }
      for i in indices {
        if Task.isCancelled { return }
        _ = await PageCache.shared.image(
          sourceID: sid, index: i, maxPixel: maxPixel, priority: .utility
        ) {
          sourceBox.pageImage(at: i, maxPixel: CGFloat(maxPixel))
        }
      }
    }
  }

  // MARK: - 进度

  private func scheduleProgressWrite() {
    progressTask?.cancel()
    progressTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.flushProgress()
    }
  }

  func flushProgress() {
    progressTask?.cancel()
    progressTask = nil
    // 打开过程中 page 已清零但当前章节已经切换；此时写入会把旧页码写到新章节。
    guard !isOpenInFlight, pageCount > 0, let entity = chapterEntity else { return }
    Queries.writeProgress(chapter: entity, page: page, context: context)
  }

  // MARK: - 偏好切换（按系列记忆）

  func setMode(_ mode: ReaderMode) {
    guard !isPDF else { return }
    prefs.mode = mode
    Queries.savePrefs(seriesKey: series.key, mode: mode)
    if mode == .webtoon {
      startDimsProbe(around: page)
      if page > 0 { restoringScroll = true }
    } else {
      dimsTask?.cancel()
      dimsTask = nil
      restoringScroll = false
    }
  }

  func setRTL(_ rtl: Bool) {
    guard !isPDF else { return }
    prefs.rtl = rtl
    Queries.savePrefs(seriesKey: series.key, rtl: rtl)
    showDirectionHint = true
    hintTask?.cancel()
    hintTask = Task {
      try? await Task.sleep(for: .seconds(1.8))
      showDirectionHint = false
    }
  }

  func setFit(_ fit: ReaderFit) {
    guard !isPDF else { return }
    prefs.fit = fit
    Queries.savePrefs(seriesKey: series.key, fit: fit)
  }

  // MARK: - 界面

  func toggleChrome() {
    withAnimation(.easeInOut(duration: 0.2)) {
      chromeVisible.toggle()
    }
  }

  /// 顶栏「收起菜单」按钮：直接进入沉浸阅读
  func hideChrome() {
    withAnimation(.easeInOut(duration: 0.2)) {
      chromeVisible = false
    }
  }

  /// 条漫滚到恢复页
  func finishRestoringScroll() {
    restoringScroll = false
  }

  /// 条漫当前页上报（视口中线所在页）；恢复进度期间不覆盖页码
  func reportVisibleFrames(_ frames: [Int: CGRect], viewportHeight: CGFloat) {
    guard !restoringScroll else { return }
    let mid = viewportHeight / 2
    var best: (index: Int, distance: CGFloat)?
    for (index, frame) in frames {
      let d = abs(frame.midY - mid)
      if best == nil || d < best!.distance {
        best = (index, d)
      }
    }
    if let best, best.index != page {
      let clamped = pageCount > 0 ? min(max(best.index, 0), pageCount - 1) : best.index
      page = clamped
      scheduleProgressWrite()
      prefetch(around: clamped)
    }
  }
}
