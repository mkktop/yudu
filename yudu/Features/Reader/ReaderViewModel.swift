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
  private var progressTask: Task<Void, Never>?
  private var hintTask: Task<Void, Never>?
  private var didShowHint = false
  /// init 时按目标章节算好的起始页（0 起；-1 表示落上一话末页）
  private var initialResume = 0

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
    self.context = context
    self.libraryService = libraryService
    self.prefs = Queries.prefs(for: series, context: context)

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
    progressTask?.cancel()
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
    let ref = chapters[currentIndex]
    current = ref
    isLoading = true
    errorMessage = nil
    dims = [:]
    dimsReadyThrough = -1

    if let opened {
      opened.access?.release()
    }
    opened = nil
    source = nil
    pageCount = 0

    let root = libraryService.libraryRoot(for: series)
    let webdavClient: WebDAVClient? = series.library?.kind == "webdav"
      ? libraryService.webdavClient(forLibrary: series.library!)
      : nil
    let cloud189Client: Cloud189Client? = series.library?.kind == "cloud189" && series.library != nil
      ? libraryService.cloud189Client(forLibrary: series.library!)
      : nil
    let opened = await PageSourceFactory.open(
      chapterPath: ref.path, kind: ref.kind, libraryRoot: root,
      seriesKey: series.key, webdavClient: webdavClient, cloud189Client: cloud189Client
    )
    guard !Task.isCancelled else { return }
    guard let opened else {
      fail("打不开这一话（文件可能被移动或权限失效）")
      return
    }

    self.opened = opened
    self.source = opened.source
    self.sourceID = ref.path
    self.pageCount = max(opened.source.pageCount, 0)
    isLoading = false

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

    // PDF / 条漫需要整章页尺寸来铺版
    if effectiveMode == .webtoon {
      startDimsProbe(upTo: landing)
    }
    prefetch(around: landing)

    // 条漫恢复位置：目标页之前的尺寸就绪后再滚动
    if effectiveMode == .webtoon, landing > 0 {
      restoringScroll = true
    }
  }

  /// 条漫尺寸渐进探测（zip 需要解压条目才能拿尺寸，逐页来）
  private func startDimsProbe(upTo: Int) {
    dimsTask?.cancel()
    let source = self.source
    let sourceID = self.sourceID
    let count = self.pageCount
    dimsTask = Task.detached(priority: .userInitiated) { [weak self] in
      guard let source else { return }
      for index in 0..<max(count, 1) {
        if Task.isCancelled { return }
        if let dims = source.pageDims(at: index) {
          await self?.applyDim(index: index, dims: dims)
        }
        if index >= upTo {
          await self?.markDimsReady(index: index)
        }
      }
      await self?.markDimsReady(index: max(count, 1))
    }
    _ = sourceID
  }

  private func applyDim(index: Int, dims: CGSize) {
    self.dims[index] = dims
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
    currentIndex = index
    await openCurrent(resume: landing)
  }

  func jumpToChapter(_ ref: ChapterRef) async {
    guard let index = chapters.firstIndex(where: { $0.path == ref.path }) else { return }
    flushProgress()
    currentIndex = index
    await openCurrent(resume: 0)
  }

  // MARK: - 预取

  private func prefetch(around index: Int) {
    guard let source, pageCount > 0 else { return }
    let maxPixel: Int = effectiveMode == .webtoon ? 1400 : 4096
    let sourceBox = source
    let sid = sourceID
    let count = pageCount
    Task.detached(priority: .utility) {
      for i in max(0, index - 1)...min(count - 1, index + 3) {
        _ = await PageCache.shared.image(sourceID: sid, index: i, maxPixel: maxPixel) {
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
    guard let entity = chapterEntity, pageCount > 0 || page > 0 else { return }
    Queries.writeProgress(chapter: entity, page: page, context: context)
  }

  // MARK: - 偏好切换（按系列记忆）

  func setMode(_ mode: ReaderMode) {
    guard !isPDF else { return }
    prefs.mode = mode
    Queries.savePrefs(seriesKey: series.key, context: context, mode: mode)
    if mode == .webtoon {
      startDimsProbe(upTo: page)
      if page > 0 { restoringScroll = true }
    }
  }

  func setRTL(_ rtl: Bool) {
    guard !isPDF else { return }
    prefs.rtl = rtl
    Queries.savePrefs(seriesKey: series.key, context: context, rtl: rtl)
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
    Queries.savePrefs(seriesKey: series.key, context: context, fit: fit)
  }

  // MARK: - 界面

  func toggleChrome() {
    withAnimation(.easeInOut(duration: 0.2)) {
      chromeVisible.toggle()
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
