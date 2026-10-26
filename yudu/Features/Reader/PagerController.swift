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

    if let props {
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
      fit: props.fit
    ) { [weak self] side in
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
  private var tapHandler: ((PagerTapSide) -> Void)?
  private var source: (any PageSource)?
  private var sourceID: String = ""
  private var readingIndex: Int = 0
  private var loadTask: Task<Void, Never>?
  private var baseScale: CGFloat = 1
  private var didLayoutOnce = false

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
    onTap: @escaping (PagerTapSide) -> Void
  ) {
    self.readingIndex = readingIndex
    self.source = source
    self.sourceID = sourceID
    self.fit = fit
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

    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
    doubleTap.numberOfTapsRequired = 2
    imageView.addGestureRecognizer(doubleTap)

    let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
    singleTap.require(toFail: doubleTap)
    imageView.addGestureRecognizer(singleTap)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    startLoading()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    loadTask?.cancel()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    scrollView.frame = view.bounds
    if !didLayoutOnce {
      didLayoutOnce = true
      relayout()
    }
  }

  private func startLoading() {
    guard imageView.image == nil, let source, loadTask == nil else { return }
    let index = readingIndex
    let sourceBox = source
    let sid = sourceID
    loadTask = Task { [weak self] in
      let image = await PageCache.shared.image(sourceID: sid, index: index, maxPixel: 4096) {
        sourceBox.pageImage(at: index, maxPixel: 4096)
      }
      guard let self, let image, !Task.isCancelled else { return }
      self.imageView.image = image
      self.relayout()
    }
  }

  private func relayout() {
    guard let image = imageView.image, scrollView.bounds.width > 0 else { return }
    let base: CGFloat
    switch fit {
    case .width:
      base = scrollView.bounds.width / image.size.width
    case .height:
      base = scrollView.bounds.height / image.size.height
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
    imageView.frame = CGRect(origin: .zero, size: image.size)

    let scaledW = image.size.width * scrollView.zoomScale
    let scaledH = image.size.height * scrollView.zoomScale
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
      let point = gesture.location(in: imageView)
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
