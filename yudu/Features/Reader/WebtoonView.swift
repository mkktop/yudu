import SwiftUI

/// 滚动几何快照：只在缩放开始时读取，普通属性不参与视图观察。
private final class ScrollMetrics: @unchecked Sendable {
  var offset = CGPoint.zero
  var insetTop: CGFloat = 0
  var viewport = CGSize.zero
  var contentSize = CGSize.zero
}

private struct ScrollMetricsSnapshot: Equatable {
  var offset: CGPoint
  var insetTop: CGFloat
  var viewport: CGSize
  var contentSize: CGSize
}

/// 条漫 / PDF 竖滚阅读
///
/// 性能要点：当前页用 `onScrollGeometryChange` 从滚动偏移换算（只在跨页时触发 action），
/// 替代每行一个 GeometryReader preference 的每帧上报；行高用每行本地 aspect，
/// 不观察 vm.dims（任何一页尺寸到达都不会重渲染其他行）。
///
/// 缩放：双指捏合 1x–4x，采用布局级缩放（行宽/行高真实放大），
/// 放大后滚动、横向拖动照常可用；捏合过程中用滚动偏移补偿，手指下的内容保持不动。
struct WebtoonView: View {
  @Bindable var vm: ReaderViewModel

  @State private var metrics = ScrollMetrics()
  @State private var scrollPosition = ScrollPosition()

  // 捏合缩放状态
  @State private var zoomScale: CGFloat = 1      // 已提交的缩放
  @State private var liveScale: CGFloat = 1      // 手势中的实时缩放
  @State private var zooming = false
  @State private var zoomStartScale: CGFloat = 1
  @State private var zoomStartOffset = CGPoint.zero   // 手势开始时的滚动偏移
  @State private var zoomStartInset: CGFloat = 0
  @State private var zoomStartPoint = CGPoint.zero    // 捏合点（视口坐标）
  @State private var zoomViewport = CGSize.zero
  /// metrics 快照对应那一帧布局的缩放系数（快照总比手势慢一帧，钳制时按比例换算）
  @State private var lastPinchScale: CGFloat = 1
  /// 缩放/复位动画期间偏移与缩放处于中间态，页码换算不可信：暂停上报，落定后补报一次
  @State private var pageReportSuspended = false
  @State private var resumeTask: Task<Void, Never>?

  private var currentScale: CGFloat { zooming ? liveScale : zoomScale }

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ScrollViewReader { proxy in
        ScrollView([.vertical, .horizontal]) {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(vm.pageCount, 1), id: \.self) { index in
              // 布局级缩放：行宽随缩放系数真实变化，滚动范围自动匹配
              WebtoonPageItem(vm: vm, index: index, width: width * currentScale)
                .id("p\(index)")
            }
            nextChapterCard
          }
          .padding(.bottom, 40)
        }
        .scrollPosition($scrollPosition)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Int.self) { scroll in
          // 视口中线落在哪一页；跨页才触发 action。
          // 缩放时内容坐标 = 滚动坐标 / 缩放系数
          let scale = max(currentScale, 1)
          let midY = (scroll.contentOffset.y + scroll.contentInsets.top
                      + scroll.containerSize.height / 2) / scale
          return Self.pageIndex(atContentY: midY, width: width, dims: vm.dims, pageCount: vm.pageCount)
        } action: { _, newPage in
          // 缩放/复位进行中换算值处于中间态（新 scale 配旧 offset），落定后由 resume 补报
          guard !pageReportSuspended else { return }
          vm.reportScrollPage(newPage)
        }
        .onScrollGeometryChange(for: ScrollMetricsSnapshot.self) { scroll in
          ScrollMetricsSnapshot(
            offset: scroll.contentOffset,
            insetTop: scroll.contentInsets.top,
            viewport: scroll.containerSize,
            contentSize: scroll.contentSize
          )
        } action: { _, snapshot in
          // 只写普通引用类型属性：不触发视图刷新
          metrics.offset = snapshot.offset
          metrics.insetTop = snapshot.insetTop
          metrics.viewport = snapshot.viewport
          metrics.contentSize = snapshot.contentSize
        }
        .simultaneousGesture(magnifyGesture)
        .onChange(of: vm.dimsReadyThrough) {
          restoreScrollIfNeeded(proxy: proxy)
        }
        .onAppear {
          restoreScrollIfNeeded(proxy: proxy)
        }
      }
    }
    .background(Color.black)
    .overlay {
      if vm.restoringScroll {
        ProgressView("正在恢复进度…")
          .tint(.white)
          .foregroundStyle(.white)
          .padding(16)
          .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  // MARK: - 缩放

  private var magnifyGesture: some Gesture {
    MagnifyGesture(minimumScaleDelta: 0.01)
      .onChanged { value in
        guard !vm.restoringScroll else { return }
        if !zooming {
          zooming = true
          zoomStartScale = zoomScale
          zoomStartOffset = metrics.offset
          zoomStartInset = metrics.insetTop
          zoomStartPoint = value.startLocation
          zoomViewport = metrics.viewport
          lastPinchScale = max(zoomStartScale, 1)
          resumeTask?.cancel()
          pageReportSuspended = true
        }
        let target = min(max(zoomStartScale * value.magnification, 1), 4)
        liveScale = target
        keepPinchPointFixed(scale: target)
        lastPinchScale = max(target, 1)
      }
      .onEnded { _ in
        zooming = false
        zoomScale = liveScale
        if zoomScale <= 1.01 {
          resetZoom()
        } else {
          // 等最后一帧 scrollTo 的布局落定，再按最终几何补报页码
          scheduleResume(after: .milliseconds(120))
        }
      }
  }

  /// 保持捏合点下的内容不动：内容坐标随缩放放大，滚动偏移同步换算
  private func keepPinchPointFixed(scale s: CGFloat) {
    let vp = zoomViewport
    guard vp.width > 0, vp.height > 0 else { return }
    let s0 = max(zoomStartScale, 1)
    let p = zoomStartPoint
    // 手势开始时捏合点下的内容坐标（内容坐标 = 滚动坐标 / 缩放系数）
    let ux = (zoomStartOffset.x + p.x) / s0
    let uy = (zoomStartOffset.y + zoomStartInset + p.y) / s0
    // 该内容点在新缩放下的屏幕位置保持不变 → 反推新的滚动偏移
    var x = s * ux - p.x
    var y = s * uy - zoomStartInset - p.y
    // 钳制到合法滚动范围：快照是上一帧布局（旧缩放）下的内容尺寸，按比例换算到目标缩放
    let ratio = s / max(lastPinchScale, 1)
    let content = CGSize(width: metrics.contentSize.width * ratio, height: metrics.contentSize.height * ratio)
    x = min(max(x, 0), max(0, content.width - vp.width))
    y = min(max(y, 0), max(0, content.height - vp.height))
    scrollPosition.scrollTo(x: x, y: y)
  }

  private func resetZoom() {
    withAnimation(.easeOut(duration: 0.2)) {
      zoomScale = 1
      liveScale = 1
    }
    // 0.2s 动画期间行宽逐帧变化、偏移被系统逐帧钳制，动画结束再补报
    scheduleResume(after: .milliseconds(300))
  }

  /// 缩放落定后按最终几何补报一次当前页（reportScrollPage 对同页是幂等的）
  private func scheduleResume(after: Duration) {
    resumeTask?.cancel()
    resumeTask = Task { @MainActor in
      try? await Task.sleep(for: after)
      guard !Task.isCancelled, pageReportSuspended else { return }
      pageReportSuspended = false
      let scale = max(currentScale, 1)
      let midY = (metrics.offset.y + metrics.insetTop + metrics.viewport.height / 2) / scale
      let page = Self.pageIndex(
        atContentY: midY, width: metrics.viewport.width,
        dims: vm.dims, pageCount: vm.pageCount
      )
      vm.reportScrollPage(page)
    }
  }

  // MARK: - 其他

  @ViewBuilder
  private var nextChapterCard: some View {
    if let next = vm.nextChapter {
      Button {
        Task { await vm.goToChapter(offset: 1, landing: 0) }
      } label: {
        HStack {
          Text("下一话 · \(next.title)")
            .font(.callout.weight(.medium))
          Image(systemName: "arrow.down.circle")
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color.white.opacity(0.08))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    } else {
      Text("已到最后一话")
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.4))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
  }

  private func restoreScrollIfNeeded(proxy: ScrollViewProxy) {
    guard vm.restoringScroll, vm.dimsReadyThrough >= vm.page else { return }
    proxy.scrollTo("p\(vm.page)", anchor: .top)
    vm.finishRestoringScroll()
  }

  /// 内容坐标 y 落在哪一页（页高 = 宽 × 比例，与 WebtoonPageItem 的布局一致）
  private static func pageIndex(atContentY y: CGFloat, width: CGFloat, dims: [Int: CGSize], pageCount: Int) -> Int {
    guard width > 0 else { return 0 }
    var top: CGFloat = 0
    for index in 0..<max(pageCount, 1) {
      let d = dims[index]
      let aspect = (d?.width ?? 0) > 0 ? d!.height / d!.width : 1.4
      let height = width * aspect
      if y < top + height { return index }
      top += height
    }
    return max(pageCount - 1, 0)
  }
}

private struct WebtoonPageItem: View {
  let vm: ReaderViewModel
  let index: Int
  let width: CGFloat

  @State private var image: UIImage?
  @State private var failed = false
  @State private var retryToken = 0
  /// 本行比例：init 时从已持久化尺寸播种（首次布局就是正确行高），
  /// 之后只由本行的探测回调 / 解码回填更新；不读 vm.dims，避免共享字典触发全体重渲染。
  @State private var aspect: CGFloat

  init(vm: ReaderViewModel, index: Int, width: CGFloat) {
    self.vm = vm
    self.index = index
    self.width = width
    if let known = vm.dims[index], known.width > 0 {
      _aspect = State(initialValue: known.height / known.width)
    } else {
      _aspect = State(initialValue: 1.4)
    }
  }

  var body: some View {
    let height = width * aspect
    ZStack {
      Color.black
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else if failed {
        VStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title3)
          Text("这一页加载失败")
            .font(.caption)
          Button("重试") { retryToken += 1 }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .foregroundStyle(.white.opacity(0.85))
      } else {
        ProgressView()
          .tint(.white.opacity(0.5))
      }
    }
    .frame(width: width, height: height)
    .clipped()
    .task(id: "\(vm.sourceID)#\(index)#\(retryToken)") {
      failed = false
      guard vm.pageCount > 0, let source = vm.source else { return }
      // 懒加载尺寸：只有滚到附近的页才解压/下载，避免打开一章就处理整章；
      // 尺寸先到先改本地行高，图片解码后再次回填精确值
      vm.requestDims(for: index) { size in
        guard size.width > 0 else { return }
        aspect = size.height / size.width
      }
      let sid = vm.sourceID
      let loaded = await PageCache.shared.image(sourceID: sid, index: index, maxPixel: 0) {
        source.pageImage(at: index, maxPixel: 0)
      }
      guard !Task.isCancelled else { return }
      if let loaded {
        image = loaded
        aspect = loaded.size.height / loaded.size.width
        // 解码完成的真实尺寸回填给阅读器（布局换算 + 持久化），不再额外探测
        vm.recordPageSize(index: index, size: loaded.size)
      } else {
        failed = true
      }
    }
    .onTapGesture {
      vm.toggleChrome()
    }
  }
}
