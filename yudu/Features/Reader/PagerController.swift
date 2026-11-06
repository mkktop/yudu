import UIKit
import SwiftUI

// MARK: - SwiftUI 包装

enum PagerTapSide {
  case left
  case right
  case center
}

/// 单页横滑阅读器：UIPageViewController + 每页可缩放 UIScrollView。
/// RTL 通过 displayIndex = n-1-page 映射（页码始终按阅读顺序递增）。
struct ReaderPager: UIViewControllerRepresentable {
  var pageCount: Int
  var page: Int
  var rtl: Bool
  var fit: ReaderFit
  var source: any PageSource
  var sourceID: String
  var onPageChanged: (Int) -> Void
  var onPageSize: ((Int, CGSize) -> Void)?
  var onTapSide: (PagerTapSide) -> Void

  func makeCoordinator() -> PagerCoordinator {
    PagerCoordinator()
  }

  func makeUIViewController(context: Context) -> PagerController {
    let vc = PagerController()
    vc.coordinator = context.coordinator
    context.coordinator.controller = vc
    vc.apply(props: self, structural: true)
    return vc
  }

  func updateUIViewController(_ vc: PagerController, context: Context) {
    context.coordinator.parent = self
    vc.apply(props: self, structural: false)
  }

  final class PagerCoordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    var parent: ReaderPager?
    weak var controller: PagerController?

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
      // 交互式滑动开始取邻页：标记过渡中，邻页新解码的大图先扣住不上屏
      controller?.beginSwipeTransition()
      guard let pageVC = viewController as? PageZoomVC else { return nil }
      return controller?.makePage(at: pageVC.displayIndex - 1)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      controller?.beginSwipeTransition()
      guard let pageVC = viewController as? PageZoomVC else { return nil }
      return controller?.makePage(at: pageVC.displayIndex + 1)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController],
      transitionCompleted completed: Bool
    ) {
      // 取消的滑动也要清过渡标记并让扣住的图落地
      controller?.endSwipeTransition()
      guard completed,
            let props = parent,
            let visible = pageViewController.viewControllers?.first as? PageZoomVC
      else { return }
      let reading = props.rtl ? props.pageCount - 1 - visible.displayIndex : visible.displayIndex
      props.onPageChanged(reading)
    }
  }
}

// MARK: - 页控制器

@MainActor
final class PagerController: UIViewController {
  var coordinator: ReaderPager.PagerCoordinator?

  private var pager: UIPageViewController!
  private var props: ReaderPager?

  /// 交互式滑动翻页进行中（手势开始取邻页 → didFinishAnimating 落定）。
  /// 期间新解码的整页大图先扣住，落定再上屏，避免在滑动动画中提交大位图造成掉帧。
  private(set) var isSwipeTransitioning = false

  func beginSwipeTransition() {
    isSwipeTransitioning = true
  }

  func endSwipeTransition() {
    guard isSwipeTransitioning else { return }
    isSwipeTransitioning = false
    for case let page as PageZoomVC in pager.viewControllers ?? [] {
      page.flushPendingLanding()
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    pager.dataSource = coordinator
    pager.delegate = coordinator
    pager.view.backgroundColor = .black
    addChild(pager)
    view.addSubview(pager.view)
    pager.view.frame = view.bounds
    pager.didMove(toParent: self)

    if props != nil {
      reload()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    pager.view.frame = view.bounds
  }

  private func displayIndex(for readingPage: Int) -> Int {
    guard let props, props.pageCount > 0 else { return 0 }
    let clamped = min(max(readingPage, 0), props.pageCount - 1)
    return props.rtl ? props.pageCount - 1 - clamped : clamped
  }

  /// 按显示序号取一页（图片页码换算成阅读顺序）
  func makePage(at displayIndex: Int) -> PageZoomVC? {
    guard let props else { return nil }
    guard displayIndex >= 0, displayIndex < props.pageCount else { return nil }
    let reading = props.rtl ? props.pageCount - 1 - displayIndex : displayIndex
    let vc = PageZoomVC(displayIndex: displayIndex)
    vc.swipeGate = { [weak self] in self?.isSwipeTransitioning ?? false }
    vc.configure(
      readingIndex: reading,
      source: props.source,
      sourceID: props.sourceID,
      fit: props.fit
    ) { size in
      props.onPageSize?(reading, size)
    } onTap: { [weak self] side in
      _ = self
      props.onTapSide(side)
    }
    return vc
  }

  private func reload() {
    guard let props, pager != nil else { return }
    let display = displayIndex(for: props.page)
    if let first = makePage(at: display) {
      pager.setViewControllers([first], direction: .forward, animated: false)
    }
  }

  func apply(props newProps: ReaderPager, structural force: Bool) {
    let old = props
    props = newProps

    let structural = force
      || old == nil
      || old!.pageCount != newProps.pageCount
      || old!.rtl != newProps.rtl
      || old!.sourceID != newProps.sourceID
      || old!.source !== newProps.source

    if structural {
      reload()
      return
    }

    // 同步目标页（点按翻页 / 跳页）
    let desired = displayIndex(for: newProps.page)
    if let visible = pager.viewControllers?.first as? PageZoomVC, visible.displayIndex != desired {
      let direction: UIPageViewController.NavigationDirection = desired >= visible.displayIndex ? .forward : .reverse
      if let next = makePage(at: desired) {
        pager.setViewControllers([next], direction: direction, animated: false)
      }
    }

    if old?.fit != newProps.fit {
      if let visible = pager.viewControllers?.first as? PageZoomVC {
        visible.fit = newProps.fit
      }
    }
  }
}

// MARK: - 单页（缩放 + 点击分区）

@MainActor
final class PageZoomVC: UIViewController, UIScrollViewDelegate {
  let displayIndex: Int
  var fit: ReaderFit {
    didSet { relayout() }
  }

  private let scrollView = UIScrollView()
  private let imageView = UIImageView()
  private let retryButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .large)
  private var tapHandler: ((PagerTapSide) -> Void)?
  private var onSize: ((CGSize) -> Void)?
  private var source: (any PageSource)?
  private var sourceID: String = ""
  private var readingIndex: Int = 0
  private var loadTask: Task<Void, Never>?
  private var baseScale: CGFloat = 1
  private var lastLayoutSize: CGSize = .zero
  /// 图片到达时布局宽高还是 0（缓存命中极快/预加载页），等下一轮布局补适配
  private var needsInitialLayout = false
  /// 滑动过渡是否进行中（由 PagerController 注入，图片落地前询问）
  var swipeGate: (() -> Bool)?
  /// 滑动过渡中解码完成的整页大图：先扣住，落定再上屏（避免动画中提交大位图掉帧）
  private var pendingImage: UIImage?

  init(displayIndex: Int) {
    self.displayIndex = displayIndex
    self.fit = .width
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

  func configure(
    readingIndex: Int,
    source: any PageSource,
    sourceID: String,
    fit: ReaderFit,
    onSize: @escaping (CGSize) -> Void,
    onTap: @escaping (PagerTapSide) -> Void
  ) {
    self.readingIndex = readingIndex
    self.source = source
    self.sourceID = sourceID
    self.fit = fit
    self.onSize = onSize
    self.tapHandler = onTap
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    scrollView.delegate = self
    scrollView.minimumZoomScale = 0.3
    scrollView.maximumZoomScale = 8
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.backgroundColor = .black
    view.addSubview(scrollView)

    imageView.contentMode = .scaleToFill
    imageView.isUserInteractionEnabled = true
    scrollView.addSubview(imageView)

    retryButton.setTitle("加载失败，点按重试", for: .normal)
    retryButton.setTitleColor(.white, for: .normal)
    retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
    retryButton.backgroundColor = UIColor(white: 0, alpha: 0.55)
    retryButton.layer.cornerRadius = 12
    retryButton.isHidden = true
    retryButton.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
    view.addSubview(retryButton)

    // 原图解码比小图慢一点：缓存未命中时给个加载反馈
    spinner.color = .white.withAlphaComponent(0.6)
    spinner.hidesWhenStopped = true
    view.addSubview(spinner)

    // 手势挂在 scrollView 而不是 imageView 上：整页适配时上下/左右有大片黑边，
    // 图片外的点击也要能翻页和收起菜单（挂在图片上时点黑边完全没反应）。
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    scrollView.addGestureRecognizer(doubleTap)

    let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
    singleTap.require(toFail: doubleTap)
    scrollView.addGestureRecognizer(singleTap)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    startLoading()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    loadTask?.cancel()
    loadTask = nil
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // 兜底：任何过渡结束后成为当前页的，把扣住的图上屏
    flushPendingLanding()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrollView.frame = view.bounds
    retryButton.frame = CGRect(
      x: (view.bounds.width - 200) / 2,
      y: (view.bounds.height - 48) / 2,
      width: 200,
      height: 48
    )
    spinner.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    // 旋转 / 分屏改变尺寸后必须按新的适宽/适高重排，否则图片停留在旧布局。
    if view.bounds.size != lastLayoutSize {
      lastLayoutSize = view.bounds.size
      relayout()
    } else if needsInitialLayout {
      relayout()
    }
  }

  private func startLoading(force: Bool = false) {
    guard let source, loadTask == nil else { return }
    // 预览已经在显示时也要允许强制重试整页加载
    guard force || imageView.image == nil else { return }
    retryButton.isHidden = true
    pendingImage = nil
    let index = readingIndex
    let sourceBox = source
    let sid = sourceID

    // 原图解码一次到位，与预取同 key：正常翻页直接命中已解码缓存（秒开且全清晰）。
    // 预取命中的页立即上屏（滑动起步动画几乎静止，无感）；未命中页若在滑动过渡中
    // 解码完成则先扣住，落定再上屏——大位图在动画进行中提交会掉帧。
    let wasCached = PageCache.shared.cached(sourceID: sid, index: index, maxPixel: 0) != nil
    spinner.startAnimating()
    loadTask = Task { [weak self] in
      let image = await PageCache.shared.image(sourceID: sid, index: index, maxPixel: 0) {
        sourceBox.pageImage(at: index, maxPixel: 0)
      }
      guard let self, !Task.isCancelled else { return }
      self.loadTask = nil
      if let image {
        if !wasCached, self.swipeGate?() == true {
          self.pendingImage = image // spinner 继续转，等过渡结束 flushPendingLanding
        } else {
          self.spinner.stopAnimating()
          self.land(image)
        }
      } else {
        self.spinner.stopAnimating()
        self.retryButton.isHidden = false
      }
    }
  }

  private func land(_ image: UIImage) {
    imageView.image = image
    relayout()
    onSize?(image.size)
  }

  /// 滑动过渡结束（或成为当前页）时上屏扣住的图
  func flushPendingLanding() {
    guard let image = pendingImage else { return }
    pendingImage = nil
    spinner.stopAnimating()
    land(image)
  }

  @objc private func retryLoad() {
    startLoading(force: true)
  }

  private func relayout() {
    guard let image = imageView.image else { return }
    guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else {
      needsInitialLayout = true
      return
    }
    needsInitialLayout = false
    let base: CGFloat
    switch fit {
    case .width:
      base = scrollView.bounds.width / image.size.width
    case .height:
      base = scrollView.bounds.height / image.size.height
    case .page:
      base = min(scrollView.bounds.width / image.size.width, scrollView.bounds.height / image.size.height)
    }
    baseScale = min(base, 4)
    scrollView.minimumZoomScale = baseScale
    scrollView.maximumZoomScale = baseScale * 5

    if scrollView.zoomScale < baseScale || scrollView.zoomScale > baseScale * 1.01 {
      scrollView.zoomScale = baseScale
    }
    layoutImageView()
  }

  private func layoutImageView() {
    guard let image = imageView.image else { return }
    let bounds = scrollView.bounds
    // 带缩放 transform 的视图不能赋 frame（frame 语义会抵消视觉缩放，图片以原始像素显示）；
    // 用 bounds + center 定位：内容占 zoomScale 缩放后的尺寸
    let scaledW = image.size.width * scrollView.zoomScale
    let scaledH = image.size.height * scrollView.zoomScale
    imageView.bounds = CGRect(origin: .zero, size: image.size)
    imageView.center = CGPoint(x: scaledW / 2, y: scaledH / 2)

    let insetX = max(0, (bounds.width - scaledW) / 2)
    let insetY = max(0, (bounds.height - scaledH) / 2)
    scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
  }

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    imageView
  }

  func scrollViewDidZoom(_ scrollView: UIScrollView) {
    layoutImageView()
  }

  @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
    // 放大状态下点按不翻页（避免拖动误触），先复位
    if scrollView.zoomScale > baseScale * 1.01 {
      scrollView.setZoomScale(baseScale, animated: true)
      return
    }
    let x = gesture.location(in: view).x
    let width = max(view.bounds.width, 1)
    let side: PagerTapSide
    if x < width / 3 {
      side = .left
    } else if x > width * 2 / 3 {
      side = .right
    } else {
      side = .center
    }
    tapHandler?(side)
  }

  @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
    guard let image = imageView.image else { return }
    if scrollView.zoomScale > baseScale * 1.01 {
      scrollView.setZoomScale(baseScale, animated: true)
    } else {
      // 点黑边时 imageView 坐标会落在图片外，聚焦到图片中心而不是左上角
      let tapped = gesture.location(in: imageView)
      let point = imageView.bounds.contains(tapped)
        ? tapped
        : CGPoint(x: image.size.width / 2, y: image.size.height / 2)
      let target = min(baseScale * 2.5, scrollView.maximumZoomScale)
      let size = scrollView.bounds.size
      let w = size.width / target
      let h = size.height / target
      let x = max(0, min(point.x - w / 2, image.size.width - w))
      let y = max(0, min(point.y - h / 2, image.size.height - h))
      scrollView.zoom(to: CGRect(x: x, y: y, width: w, height: h), animated: true)
    }
  }
}
