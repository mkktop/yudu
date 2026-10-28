import SwiftUI
import SwiftData

#if DEBUG
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

    await shot("00-empty-shelf")
    // 1. 加入库并扫描
    _ = await libraryService.addFolderLibrary(url: fixtureURL)
    try? await Task.sleep(for: .seconds(2.0))
    await shot("01-bookshelf")

    // 2. 打开第一个系列
    guard let series = firstSeries(libraryService: libraryService) else {
      writeDone(marker: "NO_SERIES")
      return
    }
    router.bookshelfPath.append(.series(series))
    try? await Task.sleep(for: .seconds(1.2))
    await shot("02-series")

    // 3. 阅读器：第一话第一页
    let chapters = Queries.orderedChapters(series)
    guard let first = chapters.first, let last = chapters.last, chapters.count > 1 else {
      writeDone(marker: "NO_CHAPTERS")
      return
    }
    router.bookshelfPath.append(.reader(series: series, startChapter: first))
    try? await Task.sleep(for: .seconds(3.0))
    await shot("03-reader-page1")

    // 4. 退出去写个进度（第 5 页），再进恢复
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))
    Queries.writeProgress(chapter: first, page: 4, context: libraryService.modelContext)
    router.bookshelfPath.append(.reader(series: series, startChapter: first))
    try? await Task.sleep(for: .seconds(3.0))
    await shot("04-reader-resumed")

    // 5. 条漫模式
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))
    Queries.savePrefs(seriesKey: series.key, context: libraryService.modelContext, mode: .webtoon)
    // 诊断：确认偏好落盘
    let diagDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent("selftest", isDirectory: true)
    let prefData = UserDefaults.standard.data(forKey: "seriesPrefs." + series.key)
    let diagText = "savedPrefs=" + (String(data: prefData ?? Data(), encoding: .utf8) ?? "nil")
    try? diagText.data(using: .utf8)?.write(to: diagDir.appendingPathComponent("diag.txt"))
    router.bookshelfPath.append(.reader(series: series, startChapter: first))
    try? await Task.sleep(for: .seconds(4.0))
    await shot("05-webtoon")

    // 6. 末话阅读（验证跨话按钮存在）
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))
    router.bookshelfPath.append(.reader(series: series, startChapter: last))
    try? await Task.sleep(for: .seconds(3.0))
    await shot("06-last-chapter")
    router.bookshelfPath.removeLast()
    try? await Task.sleep(for: .seconds(1.2))

    // 6b. PDF 阅读（深海纪行）
    let pdfDescriptor = FetchDescriptor<ChapterEntity>(predicate: #Predicate { $0.kind == "pdf" })
    if let pdfChapter = try? libraryService.modelContext.fetch(pdfDescriptor).first,
       let pdfSeries = pdfChapter.series {
      router.bookshelfPath.removeLast()
      try? await Task.sleep(for: .seconds(0.8))
      router.bookshelfPath.append(.reader(series: pdfSeries, startChapter: nil))
      try? await Task.sleep(for: .seconds(3.5))
      await shot("06b-pdf-reader")
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
      await shot("09-webdav-shelf")

      // 找 webdav 库里带 zip 章节的系列（夜行列车）；hasPrefix 不受 #Predicate 支持，取全量后过滤
      let wdSeries = ((try? libraryService.modelContext.fetch(FetchDescriptor<SeriesEntity>())) ?? [])
        .filter { $0.key.hasPrefix("webdav:") }
      if let zipSeries = wdSeries.first(where: { s in
        s.chapters.contains { $0.kind == "zip" }
      }), let zipChapter = Queries.orderedChapters(zipSeries).first(where: { $0.kind == "zip" }) {
        router.bookshelfPath.append(.series(zipSeries))
        try? await Task.sleep(for: .seconds(1.2))
        await shot("10-webdav-series")
        router.bookshelfPath.append(.reader(series: zipSeries, startChapter: zipChapter))
        try? await Task.sleep(for: .seconds(8.0)) // 留足整包下载时间
        await shot("11-webdav-reader")
        router.bookshelfPath.removeLast()
        try? await Task.sleep(for: .seconds(1.0))
        router.bookshelfPath.removeLast()
        try? await Task.sleep(for: .seconds(1.0))
      } else {
        webdavMarker = "WEBDAV_NO_ZIP_SERIES"
      }
      writeDone(marker: webdavMarker == "OK" ? "OK" : webdavMarker)
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
    await shot("12-continue-shelf")
    router.tab = .library
    try? await Task.sleep(for: .seconds(0.8))
    await shot("13-library")
    router.showImport = true
    try? await Task.sleep(for: .seconds(0.8))
    await shot("14-import")
    router.showImport = false
    try? await Task.sleep(for: .seconds(0.8))

    // 8. 统计 & 设置
    router.tab = .stats
    try? await Task.sleep(for: .seconds(1.0))
    await shot("07-stats")

    router.tab = .settings
    try? await Task.sleep(for: .seconds(1.0))
    await shot("08-settings")

    UserDefaults.standard.set(AppearanceMode.light.rawValue, forKey: "appearanceMode")
    router.tab = .bookshelf
    try? await Task.sleep(for: .seconds(0.8))
    await shot("15-light-shelf")
    UserDefaults.standard.set(AppearanceMode.dark.rawValue, forKey: "appearanceMode")
    writeDone(marker: "OK")
  }

  @MainActor
  private static func firstSeries(libraryService: LibraryService) -> SeriesEntity? {
    // 取章节最多的系列（保证有多话可验证跨话）
    let descriptor = FetchDescriptor<SeriesEntity>()
    let all = (try? libraryService.modelContext.fetch(descriptor)) ?? []
    return all.max { $0.chapters.count < $1.chapters.count }
  }

  // MARK: - 截图

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
