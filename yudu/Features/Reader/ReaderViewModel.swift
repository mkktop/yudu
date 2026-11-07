import SwiftUI
import SwiftData
import Observation

/// 阅读器状态机：当前话、页码、偏好、跨话连读、进度落库
@MainActor
@Observable
final class ReaderViewModel {

  // 输入
  /// nil = 网盘浏览器试读（未挂载章节）：不落进度、不落偏好
  private let series: SeriesEntity?
  /// 试读模式预解析好的客户端（挂载模式按 series.library 现查）
  private let previewWebDAV: WebDAVClient?
  private let previewCloud189: Cloud189Client?
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
  /// 条漫页尺寸（渐进加载）。
  /// ObservationIgnored：尺寸字典一变就全体条漫行重渲染是滚动卡顿源，
  /// 行高改为条漫行本地 aspect（init 播种 + 本行探测回调 / 解码回填），字典只喂布局换算与持久化。
  @ObservationIgnored private(set) var dims: [Int: CGSize] = [:]
  /// dims 每次变化递增；条漫用它判断“页高前缀和”缓存是否需要重建，避免每帧扫全表。
  @ObservationIgnored private(set) var dimsRevision = 0
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
  /// 下一次进度落库是否跳过“阅读页数”统计（跳页、拖滑条、打开章节的初始落点）。
  private var progressSeek = false

  var isPDF: Bool { current?.isPDF ?? false }
  var effectiveMode: ReaderMode { isPDF ? .webtoon : prefs.mode }

  var prevChapter: ChapterRef? {
    chapters.indices.contains(currentIndex - 1) ? chapters[currentIndex - 1] : nil
  }

  var nextChapter: ChapterRef? {
    chapters.indices.contains(currentIndex + 1) ? chapters[currentIndex + 1] : nil
  }

  init(series: SeriesEntity, startChapter: ChapterEntity?, context: ModelContext, libraryService: LibraryService) {
    self.series = series
    self.previewWebDAV = nil
    self.previewCloud189 = nil
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

  /// 网盘浏览器试读：直接驱动阅读管线，不经过任何挂载书库（无进度、无偏好持久化）
  init(
    previewChapters: [ChapterRef], index: Int,
    webdavClient: WebDAVClient?, cloud189Client: Cloud189Client?,
    context: ModelContext, libraryService: LibraryService
  ) {
    self.series = nil
    self.previewWebDAV = webdavClient
    self.previewCloud189 = cloud189Client
    self.context = context
    self.libraryService = libraryService
    let defaults = ReaderDefaults.load()
    self.prefs = EffectivePrefs(mode: defaults.mode, rtl: defaults.rtl, fit: defaults.fit)
    self.chapters = previewChapters
    if previewChapters.indices.contains(index) {
      currentIndex = index
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
    series?.chapters.first { $0.path == current?.path }
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
    dimsRevision &+= 1
    dimsReadyThrough = -1
    restoringScroll = false

    if let opened {
      opened.access?.release()
    }
    opened = nil
    source = nil

    let root = series.flatMap { libraryService.libraryRoot(for: $0) }
    let webdavClient: WebDAVClient?
    let cloud189Client: Cloud189Client?
    if let series {
      webdavClient = series.library?.kind == "webdav"
        ? libraryService.webdavClient(forLibrary: series.library!)
        : nil
      cloud189Client = series.library?.kind == "cloud189"
        ? libraryService.cloud189Client(forLibrary: series.library!)
        : nil
    } else {
      webdavClient = previewWebDAV
      cloud189Client = previewCloud189
    }
    let opened = await PageSourceFactory.open(
      chapterPath: ref.path, kind: ref.kind, libraryRoot: root,
      seriesKey: ref.seriesKey, webdavClient: webdavClient, cloud189Client: cloud189Client,
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
      dimsRevision &+= 1
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
    setPage(landing, animated: false, seek: true)

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
  /// onDims 在主线程回调本页尺寸，供条漫行先改行高（避免解码完成后跳变）。
  func requestDims(for index: Int, onDims: ((CGSize) -> Void)? = nil) {
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
          self.dimsRevision &+= 1
          self.scheduleDimsSave()
          onDims?(value)
        }
      }
    }
  }

  private func applyDim(index: Int, dims: CGSize, epoch: Int) {
    guard epoch == openEpoch, self.dims[index] == nil else { return }
    self.dims[index] = dims
    dimsRevision &+= 1
    scheduleDimsSave()
  }

  /// 页图解码完成后回填尺寸（单页模式也记录，之后切条漫不用再探测）
  func recordPageSize(index: Int, size: CGSize) {
    guard index >= 0, index < pageCount, size.width > 0, size.height > 0 else { return }
    guard dims[index] == nil else { return }
    dims[index] = size
    dimsRevision &+= 1
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

  func setPage(_ newPage: Int, animated: Bool = true, seek: Bool = false) {
    let clamped = pageCount > 0 ? min(max(newPage, 0), pageCount - 1) : max(newPage, 0)
    if seek { progressSeek = true }
    page = clamped
    scheduleProgressWrite()
    prefetch(around: clamped)
  }

  /// 跳页/拖滑条：更新进度但不把跨过的页数计入阅读统计。
  func jumpToPage(_ newPage: Int) {
    setPage(newPage, seek: true)
    if effectiveMode == .webtoon {
      startDimsProbe(around: page)
    }
  }

  /// 单页模式点按/滑动翻页：越界自动跨话
  func step(_ direction: Int) {
    let target = page + direction
    if pageCount == 0 || target <= pageCount - 1, target >= 0 {
      setPage(target)
    } else if direction > 0, nextChapter != nil {
      Task { await goToChapter(offset: 1, landing: 0) }
    } else if direction < 0, prevChapter != nil {
      // 与底栏「上一话」保持一致：回到续读位置，而不是末页；
      // 末页会在 600ms 后被 writeProgress 标成“已读完”，用户只是返回也会误标完成。
      Task { await goToPreviousChapter() }
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
    let entity = series?.chapters.first { $0.path == previous.path }
    let landing = entity.map { Queries.resumePage($0) } ?? 0
    await goToChapter(offset: -1, landing: landing)
  }

  func jumpToChapter(_ ref: ChapterRef) async {
    guard let index = chapters.firstIndex(where: { $0.path == ref.path }) else { return }
    flushProgress()
    openTask?.cancel()
    currentIndex = index
    let landing = series?.chapters.first { $0.path == ref.path }.map { Queries.resumePage($0) } ?? 0
    await openCurrent(resume: landing)
  }

  // MARK: - 预取

  /// 预取与前台同一把钥匙：全部原图解码（maxPixel 0），
  /// 正常翻页直接命中已解码缓存秒开，不存在"预览 → 大图"二次解码。
  /// - 云端：向前 3 页（网络延迟比解码慢一个量级，最需要预取；
  ///   顺序阅读时预下的页反正都要读，不浪费流量）
  /// - 本地单页：下一页最优先，随后 +2、上一页、+3——连翻快时深页会被取消跳过，
  ///   停留阅读时才铺开（用空闲解码能力换前向流畅）
  /// - 本地条漫：向前 4 页（竖滚消耗快），回滚保留 1 页
  private func prefetch(around index: Int) {
    prefetchTask?.cancel()
    guard let source, pageCount > 0 else { return }
    let remote = source.isRemote
    let order: [Int]
    if remote {
      order = [index + 1, index + 2, index + 3]
    } else if effectiveMode == .webtoon {
      order = [index + 1, index + 2, index + 3, index + 4, index - 1]
    } else {
      order = [index + 1, index + 2, index - 1, index + 3]
    }
    let indices = order.filter { $0 >= 0 && $0 < pageCount }
    guard !indices.isEmpty else { return }
    let sourceBox = source
    let sid = sourceID
    prefetchTask = Task.detached(priority: .utility) {
      if remote {
        // 当前页没缓存好之前不抢带宽（最多等 2.5 秒）：
        // 慢网下预取和正在看的页抢同一条管道，先保住落地页
        for _ in 0..<25 {
          if Task.isCancelled { return }
          if PageCache.shared.cached(sourceID: sid, index: index, maxPixel: 0) != nil { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
      }
      for i in indices {
        if Task.isCancelled { return }
        _ = await PageCache.shared.image(
          sourceID: sid, index: i, maxPixel: 0, priority: .utility
        ) {
          sourceBox.pageImage(at: i, maxPixel: 0)
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
    let seek = progressSeek
    progressSeek = false
    Queries.writeProgress(chapter: entity, page: page, context: context, countPages: !seek)
  }

  // MARK: - 偏好切换（按系列记忆）

  func setMode(_ mode: ReaderMode) {
    guard !isPDF else { return }
    prefs.mode = mode
    if let series { Queries.savePrefs(seriesKey: series.key, mode: mode) }
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
    if let series { Queries.savePrefs(seriesKey: series.key, rtl: rtl) }
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
    if let series { Queries.savePrefs(seriesKey: series.key, fit: fit) }
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

  /// 条漫滚动上报当前页（视口中线所在页，由 onScrollGeometryChange 在跨页时触发）；
  /// 恢复进度期间不覆盖页码
  func reportScrollPage(_ index: Int) {
    guard !restoringScroll, pageCount > 0 else { return }
    let clamped = min(max(index, 0), pageCount - 1)
    guard clamped != page else { return }
    page = clamped
    scheduleProgressWrite()
    prefetch(around: clamped)
  }
}
