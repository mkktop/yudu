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
  /// 云端源不先解预览：避免为预览再下载一次整页大图
  var isRemote: Bool
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
      guard let pageVC = viewController as? PageZoomVC else { return nil }
      return controller?.makePage(at: pageVC.displayIndex - 1)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      guard let pageVC = viewController as? PageZoomVC else { return nil }
      return controller?.makePage(at: pageVC.displayIndex + 1)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController],
      transitionCompleted completed: Bool
    ) {
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
    vc.configure(
      readingIndex: reading,
      source: props.source,
      sourceID: props.sourceID,
      fit: props.fit,
      isRemote: props.isRemote
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
  private var tapHandler: ((PagerTapSide) -> Void)?
  private var onSize: ((CGSize) -> Void)?
  private var source: (any PageSource)?
  private var sourceID: String = ""
  private var readingIndex: Int = 0
  private var isRemote = false
  private var loadTask: Task<Void, Never>?
  private var baseScale: CGFloat = 1
  private var lastLayoutSize: CGSize = .zero
  /// 图片到达时布局宽高还是 0（缓存命中极快/预加载页），等下一轮布局补适配
  private var needsInitialLayout = false

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
    isRemote: Bool,
    onSize: @escaping (CGSize) -> Void,
    onTap: @escaping (PagerTapSide) -> Void
  ) {
    self.readingIndex = readingIndex
    self.source = source
    self.sourceID = sourceID
    self.fit = fit
    self.isRemote = isRemote
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

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrollView.frame = view.bounds
    retryButton.frame = CGRect(
      x: (view.bounds.width - 200) / 2,
      y: (view.bounds.height - 48) / 2,
      width: 200,
      height: 48
    )
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
    let index = readingIndex
    let sourceBox = source
    let sid = sourceID

    // 本地源先显示预取好的 2048 预览（秒开），再解 4096 替换；
    // 云端源只解一次 4096，避免为预览再下载一次整页大图。
    if !isRemote,
       let preview = PageCache.shared.cached(sourceID: sid, index: index, maxPixel: 2048) {
      imageView.image = preview
      relayout()
      onSize?(preview.size)
    }

    loadTask = Task { [weak self] in
      let image = await PageCache.shared.image(sourceID: sid, index: index, maxPixel: 4096) {
        sourceBox.pageImage(at: index, maxPixel: 4096)
      }
      guard let self, !Task.isCancelled else { return }
      self.loadTask = nil
      if let image {
        self.imageView.image = image
        self.relayout()
        self.onSize?(image.size)
      } else {
        self.retryButton.isHidden = false
      }
    }
  }

  @objc private func retryLoad() {
    startLoading(force: true)
  }

  private func relayout() {
    guard let image = imageView.image else { return }
    guard scrollView.bounds.width > 0, scrollView.bounds.height > 0 else {
      needsInitialLayout = true
      Diag.log("relayout[\(displayIndex)] 布局未就绪，标记待补")
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
    Diag.log("relayout[\(displayIndex)] fit=\(fit.rawValue) bounds=\(scrollView.bounds.size) img=\(image.size) base=\(baseScale) zoom=\(scrollView.zoomScale)")
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
