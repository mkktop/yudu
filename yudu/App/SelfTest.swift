import SwiftUI
import SwiftData

#if DEBUG
/// 阅读器打开成功时回填页数；smoke test 据此判断“真的在读”，而不是只看截图存在。
@MainActor
enum ReaderProbe {
  static var lastPageCount = 0
  /// 冒烟测试用：验证收起菜单后的界面状态
  static weak var currentViewModel: ReaderViewModel?
}

/// 无头自测：模拟器里 `simctl launch <udid> <bundleid> -yuduSelfTest <fixture路径>` 触发。
/// 跑完把截图写到 App Documents/selftest/，并写 done 标记。
enum SelfTest {

  static func maybeRun(router: AppRouter, libraryService: LibraryService) {
    let args = ProcessInfo.processInfo.arguments
    guard let index = args.firstIndex(of: "-yuduSelfTest"), args.count > index + 1 else { return }
    let fixturePath = args[index + 1]
    let webdavURL: URL? = {
      guard let widx = args.firstIndex(of: "-yuduWebDAV"), args.count > widx + 1,
            let url = URL(string: args[widx + 1]) else { return nil }
      return url
    }()
    Task {
      await run(fixturePath: fixturePath, webdavURL: webdavURL, router: router, libraryService: libraryService)
    }
  }

  @MainActor
  static func run(fixturePath: String, webdavURL: URL?, router: AppRouter, libraryService: LibraryService) async {
    let fixtureURL = URL(fileURLWithPath: fixturePath)

    // 0. 远程尺寸探测只读文件头：用生成的 JPEG/PNG 验证前缀解析
    guard verifyPrefixDims() else {
      writeDone(marker: "DIMS_PREFIX_FAIL")
      return
    }

    shot("00-empty-shelf")
    // 1. 加入库并扫描
    _ = await libraryService.addFolderLibrary(url: fixtureURL)
    try? await Task.sleep(for: .seconds(2.0))
    shot("01-bookshelf")

    // 2. 打开第一个系列
    guard let series = firstSeries(libraryService: libraryService) else {
      writeDone(marker: "NO_SERIES")
      return
    }
    router.bookshelfPath.append(.series(series))
    try? await Task.sleep(for: .seconds(1.2))
    shot("02-series")

    // 3. 阅读器：第一话第一页
    let chapters = Queries.orderedChapters(series)
    guard let first = chapters.first, let last = chapters.last, chapters.count > 1 else {
      writeDone(marker: "NO_CHAPTERS")
      return
    }
    router.openReader(series: series, startChapter: first)
    try? await Task.sleep(for: .seconds(3.0))
    shot("03-reader-page1")
    guard ReaderProbe.lastPageCount > 0 else {
      writeDone(marker: "READER_NO_PAGES")
      return
    }

    // 菜单收起态：只留整页画面（顶栏/底栏都应消失）
    ReaderProbe.currentViewModel?.hideChrome()
    try? await Task.sleep(for: .seconds(0.6))
    shot("03b-reader-chrome-hidden")
    ReaderProbe.currentViewModel?.toggleChrome()
    try? await Task.sleep(for: .seconds(0.5))

    // 4. 退出去写个进度（第 5 页），再进恢复
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))
    Queries.writeProgress(chapter: first, page: 4, context: libraryService.modelContext)
    router.openReader(series: series, startChapter: first)
    try? await Task.sleep(for: .seconds(3.0))
    shot("04-reader-resumed")
    guard ReaderProbe.lastPageCount > 0 else {
      writeDone(marker: "RESUME_NO_PAGES")
      return
    }

    // 5. 条漫模式
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))
    Queries.savePrefs(seriesKey: series.key, mode: .webtoon)
    // 诊断：确认偏好落盘
    let diagDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent("selftest", isDirectory: true)
    let prefData = UserDefaults.standard.data(forKey: "seriesPrefs." + series.key)
    let diagText = "savedPrefs=" + (String(data: prefData ?? Data(), encoding: .utf8) ?? "nil")
    try? diagText.data(using: .utf8)?.write(to: diagDir.appendingPathComponent("diag.txt"))
    router.openReader(series: series, startChapter: first)
    try? await Task.sleep(for: .seconds(4.0))
    shot("05-webtoon")
    guard ReaderProbe.lastPageCount > 0 else {
      writeDone(marker: "WEBTOON_NO_PAGES")
      return
    }

    // 6. 末话阅读（验证跨话按钮存在）
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))
    router.openReader(series: series, startChapter: last)
    try? await Task.sleep(for: .seconds(3.0))
    shot("06-last-chapter")
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))

    // 6a. 本地 ZIP / CBZ 阅读（压缩包列传）
    let zipDescriptor = FetchDescriptor<ChapterEntity>(predicate: #Predicate { $0.kind == "zip" })
    if let zipChapter = try? libraryService.modelContext.fetch(zipDescriptor).first,
       let zipSeries = zipChapter.series {
      router.openReader(series: zipSeries, startChapter: zipChapter)
      try? await Task.sleep(for: .seconds(3.0))
      shot("06a-zip-reader")
      guard ReaderProbe.lastPageCount > 0 else {
        writeDone(marker: "ZIP_READER_NO_PAGES")
        return
      }
      router.bookshelfPath.removeLast()
      try? await Task.sleep(for: .seconds(1.2))
    }

    // 6b. PDF 阅读（深海纪行）
    let pdfDescriptor = FetchDescriptor<ChapterEntity>(predicate: #Predicate { $0.kind == "pdf" })
    if let pdfChapter = try? libraryService.modelContext.fetch(pdfDescriptor).first,
       let pdfSeries = pdfChapter.series {
      router.bookshelfPath.removeLast()
      try? await Task.sleep(for: .seconds(0.8))
      router.openReader(series: pdfSeries, startChapter: nil)
      try? await Task.sleep(for: .seconds(3.5))
      shot("06b-pdf-reader")
      guard ReaderProbe.lastPageCount > 0 else {
        writeDone(marker: "PDF_READER_NO_PAGES")
        return
      }
      router.bookshelfPath.removeLast()
      try? await Task.sleep(for: .seconds(1.2))
    }

    // 6c. WebDAV 挂载与远程阅读
    if let webdavURL {
      let result = await libraryService.addWebDAVLibrary(baseURL: webdavURL, username: nil, password: nil)
      var webdavMarker = "OK"
      if case .failure(let failure) = result {
        webdavMarker = "WEBDAV_FAIL:\(failure.message)"
      }
      // 诊断：挂载后的系列数与扫描错误
      let wdCount = ((try? libraryService.modelContext.fetch(FetchDescriptor<LibraryEntity>())) ?? [])
        .filter { $0.kind == "webdav" }
        .map { "\($0.name):series=\($0.series.count)" }
        .joined(separator: "; ")
      let diagText2 = "libs=[\(wdCount)] errors=\(libraryService.lastErrors.joined(separator: " | "))"
      try? diagText2.data(using: .utf8)?.write(to: diagDir.appendingPathComponent("webdav-diag.txt"))
      try? await Task.sleep(for: .seconds(3.0))

      // 增量扫描：远端没变化时应复用缓存，系列数量保持不变。
      if let wdLibrary = ((try? libraryService.modelContext.fetch(FetchDescriptor<LibraryEntity>())) ?? [])
        .first(where: { $0.kind == "webdav" }) {
        var waited = 0
        while libraryService.isScanning && waited < 60 {
          try? await Task.sleep(for: .milliseconds(500))
          waited += 1
        }
        let before = wdLibrary.series.count
        // 在远端目录里临时加一话：增量扫描必须能通过目录指纹变化发现它。
        let probeTitle = "月海来信"
        let probeSeries = wdLibrary.series.first(where: { $0.title == probeTitle })
        let chaptersBefore = probeSeries?.chapters.count ?? 0
        let seriesDir = fixtureURL.appendingPathComponent(probeTitle, isDirectory: true)
        let chapterDirs = (try? FileManager.default.contentsOfDirectory(
          at: seriesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var sourceImage: URL?
        for dir in chapterDirs {
          let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
          )) ?? []
          if let image = files.first(where: { MediaSniff.isImage($0.lastPathComponent) }) {
            sourceImage = image
            break
          }
        }
        let newChapterDir = seriesDir.appendingPathComponent("第1卷 第99话", isDirectory: true)
        try? FileManager.default.createDirectory(at: newChapterDir, withIntermediateDirectories: true)
        if let sourceImage {
          try? FileManager.default.copyItem(
            at: sourceImage, to: newChapterDir.appendingPathComponent("001.jpg")
          )
        }

        let started = Date()
        await libraryService.rescan(wdLibrary, mode: .incremental)
        let elapsed = Date().timeIntervalSince(started)
        let after = wdLibrary.series.count
        let chaptersAfter = probeSeries?.chapters.count ?? 0
        let finished = Date()
        let summary = libraryService.lastScanSummary ?? "nil"
        let line = "incremental: series \(before)->\(after)"
          + " chapters \(chaptersBefore)->\(chaptersAfter)"
          + " in " + String(format: "%.1f", elapsed) + "s"
          + " start=\(started.timeIntervalSince1970) end=\(finished.timeIntervalSince1970)"
          + " summary=\(summary)"
        try? line.data(using: .utf8)?.write(to: diagDir.appendingPathComponent("incremental.txt"))
        if before == 0 || after != before { webdavMarker = "INCREMENTAL_SCAN_FAIL" }
        if chaptersBefore == 0 || chaptersAfter != chaptersBefore + 1 {
          webdavMarker = "INCREMENTAL_MISS_NEW_CHAPTER"
        }
      }

      shot("09-webdav-shelf")

      // 找 webdav 库里带 zip 章节的系列（夜行列车）；hasPrefix 不受 #Predicate 支持，取全量后过滤
      let wdSeries = ((try? libraryService.modelContext.fetch(FetchDescriptor<SeriesEntity>())) ?? [])
        .filter { $0.key.hasPrefix("webdav:") }
      if let zipSeries = wdSeries.first(where: { s in
        s.chapters.contains { $0.kind == "zip" }
      }), let zipChapter = Queries.orderedChapters(zipSeries).first(where: { $0.kind == "zip" }) {
        router.bookshelfPath.append(.series(zipSeries))
        try? await Task.sleep(for: .seconds(1.2))
        shot("10-webdav-series")
        router.openReader(series: zipSeries, startChapter: zipChapter)
        try? await Task.sleep(for: .seconds(8.0)) // 留足整包下载时间
        shot("11-webdav-reader")
        router.bookshelfPath.removeLast()
        try? await Task.sleep(for: .seconds(1.0))
        router.bookshelfPath.removeLast()
        try? await Task.sleep(for: .seconds(1.0))
      } else {
        webdavMarker = "WEBDAV_NO_ZIP_SERIES"
      }

      // 11b. WebDAV 散图章节 + 条漫：验证远程尺寸只读图头、预取策略与远端图片加载
      if let folderSeries = wdSeries.first(where: { series in
        series.chapters.contains { $0.kind == "folder" }
      }), let folderChapter = Queries.orderedChapters(folderSeries).first(where: { $0.kind == "folder" }) {
        Queries.savePrefs(seriesKey: folderSeries.key, mode: .webtoon)
        ReaderProbe.lastPageCount = 0
        router.openReader(series: folderSeries, startChapter: folderChapter)
        try? await Task.sleep(for: .seconds(6.0))
        shot("11b-webdav-folder-webtoon")
        guard ReaderProbe.lastPageCount > 0 else {
          writeDone(marker: "WEBDAV_FOLDER_NO_PAGES")
          return
        }
        router.bookshelfPath.removeLast()
        try? await Task.sleep(for: .seconds(1.0))
      } else {
        webdavMarker = "WEBDAV_NO_FOLDER_CHAPTER"
      }
      if webdavMarker != "OK" {
        writeDone(marker: webdavMarker)
        return
      }
    }

    // 离线 CI 不请求真实云服务；正常诊断仍可显式运行协议探测。
    if !ProcessInfo.processInfo.arguments.contains("-yuduOfflineSelfTest") {
    do {
      let probe = Cloud189Client()
      let qr = try await probe.beginQRLogin()
      let image = Cloud189LoginView.makeQRCode(text: qr.uuid)
      let qrDiag = "cloud189 qr: uuid=\(qr.uuid.prefix(24))… image=\(image != nil ? "\(Int(image!.size.width))px" : "nil")"
      try? qrDiag.data(using: .utf8)?.write(to: diagDir.appendingPathComponent("cloud189-diag.txt"))
    } catch {
      try? ("cloud189 qr failed: \(error.localizedDescription)")
        .data(using: .utf8)?.write(to: diagDir.appendingPathComponent("cloud189-diag.txt"))
    }

    }

    // 7. 返回书架，验证阅读后续读卡、书库与全局导入面板。
    router.bookshelfPath = []
    try? await Task.sleep(for: .seconds(0.8))
    shot("12-continue-shelf")
    router.tab = .library
    try? await Task.sleep(for: .seconds(0.8))
    shot("13-library")
    router.showImport = true
    try? await Task.sleep(for: .seconds(0.8))
    shot("14-import")
    router.showImport = false
    try? await Task.sleep(for: .seconds(0.8))

    // 8. 统计 & 设置
    router.tab = .stats
    try? await Task.sleep(for: .seconds(1.0))
    shot("07-stats")
    // 滚到下半屏，验证放大后的热力图与选中日期信息栏。
    scrollMainView(by: 520)
    try? await Task.sleep(for: .seconds(0.6))
    shot("07b-stats-heatmap")
    scrollMainView(by: -520)
    try? await Task.sleep(for: .seconds(0.3))

    router.tab = .settings
    try? await Task.sleep(for: .seconds(1.0))
    shot("08-settings")
    // 滚到护眼设置，验证总开关默认关闭、滑块置灰。
    scrollMainView(by: 470)
    try? await Task.sleep(for: .seconds(0.6))
    shot("08b-settings-eye-care")
    scrollMainView(by: -470)
    try? await Task.sleep(for: .seconds(0.3))

    UserDefaults.standard.set(AppearanceMode.light.rawValue, forKey: "appearanceMode")
    router.tab = .bookshelf
    try? await Task.sleep(for: .seconds(0.8))
    shot("15-light-shelf")
    UserDefaults.standard.set(AppearanceMode.dark.rawValue, forKey: "appearanceMode")
    writeDone(marker: "OK")
  }

  /// 远程页源只取 256KB 图头读尺寸，这里验证 JPEG/PNG 前缀解析是否可靠。
  @MainActor
  private static func verifyPrefixDims() -> Bool {
    let size = CGSize(width: 1200, height: 1800)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      ctx.cgContext.setFillColor(UIColor.systemTeal.cgColor)
      ctx.cgContext.fill(CGRect(origin: .zero, size: size))
    }
    guard let jpeg = image.jpegData(compressionQuality: 0.9),
          let j = ImageDecode.dims(fromPrefix: Data(jpeg.prefix(8192))),
          abs(j.width - size.width) < 1, abs(j.height - size.height) < 1
    else { return false }
    guard let png = image.pngData(),
          let p = ImageDecode.dims(fromPrefix: Data(png.prefix(64))),
          abs(p.width - size.width) < 1, abs(p.height - size.height) < 1
    else { return false }
    return true
  }

  @MainActor
  private static func firstSeries(libraryService: LibraryService) -> SeriesEntity? {
    // 取章节最多的系列（保证有多话可验证跨话）
    let descriptor = FetchDescriptor<SeriesEntity>()
    let all = (try? libraryService.modelContext.fetch(descriptor)) ?? []
    return all.max { $0.chapters.count < $1.chapters.count }
  }

  // MARK: - 截图

  /// 把当前页面的主滚动视图上下移动，用于截到首屏之外的内容。
  @MainActor
  static func scrollMainView(by dy: CGFloat) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.keyWindow,
          let scroll = mainScrollView(in: window) else { return }
    let maxY = max(0, scroll.contentSize.height - scroll.bounds.height
      + scroll.adjustedContentInset.bottom)
    let y = min(maxY, max(0, scroll.contentOffset.y + dy))
    scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: y), animated: false)
  }

  @MainActor
  private static func mainScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView,
       scroll.bounds.height > 300,
       scroll.contentSize.height > scroll.bounds.height + 40 {
      return scroll
    }
    for sub in view.subviews {
      if let found = mainScrollView(in: sub) { return found }
    }
    return nil
  }

  @MainActor
  static func shot(_ name: String) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.keyWindow else { return }
    let size = window.bounds.size
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent("selftest", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(name).jpg")
    try? image.jpegData(compressionQuality: 0.85)?.write(to: url)
    NSLog("[SelfTest] shot \(name)")
  }

  @MainActor
  static func writeDone(marker: String) {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent("selftest", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? marker.data(using: .utf8)?
      .write(to: dir.appendingPathComponent("done.txt"))
    NSLog("[SelfTest] done: \(marker)")
  }
}
#endif
