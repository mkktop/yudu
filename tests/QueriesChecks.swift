import Foundation
import SwiftData

/// 在 macOS 上用真实 SwiftData 内存库验证续读与统计逻辑；无需设备或测试账号。
@main
struct QueriesChecks {
  @MainActor
  static func main() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
      for: LibraryEntity.self, SeriesEntity.self, ChapterEntity.self,
      ProgressEntity.self, ReadingLogEntity.self,
      configurations: configuration
    )
    let context = container.mainContext
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }
    let series = SeriesEntity(key: "test", title: "轨道测试")
    context.insert(series)
    expect(Queries.continueTarget(series) == nil, "空系列不能进入不存在的章节")
    expect(Queries.info(series).fraction == 0, "空系列进度必须是零")
    let first = ChapterEntity(path: "test/1.cbz", title: "第 1 话")
    let second = ChapterEntity(path: "test/2.cbz", title: "第 2 话")
    first.sortIndex = 0; second.sortIndex = 1
    first.pageCount = 100; second.pageCount = 100
    first.series = series; second.series = series
    series.chapters = [second, first]
    context.insert(first); context.insert(second)
    expect(Queries.orderedChapters(series).first === first, "目录必须使用章节顺序")
    expect(Queries.info(series).status == .unread, "未读系列状态")
    expect(Queries.continueItems([series]).isEmpty, "未打开的系列不进入续读")
    Queries.writeProgress(chapter: first, page: 19, context: context)
    expect(Queries.info(series).status == .reading, "读过部分页面即为在读")
    expect(abs(Queries.info(series).fraction - 0.1) < 0.001, "单话部分进度应计入全书百分比")
    expect(Queries.resumePage(first) == 19, "续读恢复页码")
    expect(Queries.continueItems([series]).first?.chapter === first, "续读卡和阅读器使用同一目标")
    Queries.setCompleted(first, completed: true, context: context)
    expect(Queries.continueTarget(series) === second, "一话完成后选择下一未完成话")
    expect(Queries.continueItems([series]).first?.chapter === second, "续读卡不能停留在上一已完成话")
    expect(Queries.continueItems([series]).first?.page == 0, "新话从第一页开始")
    Queries.setCompleted(second, completed: true, context: context)
    expect(Queries.info(series).fraction == 1, "全书完成进度为百分之百")
    expect(Queries.continueItems([series]).isEmpty, "完成的系列退出续读区域")
    Queries.setCompleted(first, completed: false, context: context)
    expect(first.progress == nil, "标记未读应清除该章节的进度记录")
    expect(Queries.continueTarget(series) === first, "取消已读后可再次续读")
    Queries.setCompleted(second, completed: false, context: context)
    expect(Queries.info(series).status == .unread, "全部章节标记未读后，系列也应回到未读")
    expect(Queries.continueItems([series]).isEmpty, "全部未读的系列不应保留在续读区域")
    Queries.resetProgress(series, context: context)
    expect(series.lastReadAt == nil && first.progress == nil && second.progress == nil, "重置清理全部阅读进度")
    expect(Queries.info(series).status == .unread, "重置后回到未读")
    expect(Queries.continueItems([series], limit: -1).isEmpty, "负数 limit 不崩溃")

    // 云端章节页数未知（pageCount 0）时必须信任已存进度；
    // 按旧逻辑会当成 1 页并把续读位置丢回第 0 页，重扫一次就丢进度。
    let cloudSeries = SeriesEntity(key: "cloud", title: "云端漫画")
    context.insert(cloudSeries)
    let cloudChapter = ChapterEntity(path: "cloud/1.zip", title: "云端第 1 话")
    cloudChapter.series = cloudSeries
    context.insert(cloudChapter)
    Queries.writeProgress(chapter: cloudChapter, page: 19, context: context)
    expect(cloudChapter.pageCount == 0, "云端扫描出的页数是未知（0）")
    expect(Queries.resumePage(cloudChapter) == 19, "页数未知时按已存进度续读")
    cloudChapter.pageCount = 50
    expect(Queries.resumePage(cloudChapter) == 19, "阅读器回填页数后续读位置保持")
    Queries.writeProgress(chapter: cloudChapter, page: 3, context: context)
    expect(cloudChapter.progress?.page == 3, "页数已知后正常按页写入")

    // 删除章节必须级联删除进度（deleteRule: .cascade），否则库会积累孤儿进度行。
    let progressCountBefore = (try? context.fetch(FetchDescriptor<ProgressEntity>()))?.count ?? 0
    let cascadeChapter = ChapterEntity(path: "cascade/1.zip", title: "级联第 1 话")
    cascadeChapter.series = cloudSeries
    context.insert(cascadeChapter)
    let cascadeProgress = ProgressEntity(page: 5)
    cascadeProgress.chapter = cascadeChapter
    context.insert(cascadeProgress)
    try context.save()
    context.delete(cascadeChapter)
    try context.save()
    let progressCountAfter = (try? context.fetch(FetchDescriptor<ProgressEntity>()))?.count ?? 0
    expect(progressCountAfter == progressCountBefore, "删除章节应级联删除其进度记录")

    // WebDAV 同源判断：跨源 href 不能附带 Basic 凭据
    expect(
      WebDAVOrigin.isSameOrigin(
        URL(string: "https://nas.local/dav/a")!, URL(string: "https://nas.local/dav")!
      ),
      "同主机同端口同源"
    )
    expect(
      WebDAVOrigin.isSameOrigin(
        URL(string: "https://nas.local:8443/x")!, URL(string: "https://nas.local:8443/y")!
      ),
      "显式端口相同视为同源"
    )
    expect(
      !WebDAVOrigin.isSameOrigin(
        URL(string: "https://nas.local/x")!, URL(string: "http://nas.local/x")!
      ),
      "协议不同不同源"
    )
    expect(
      !WebDAVOrigin.isSameOrigin(
        URL(string: "https://nas.local/x")!, URL(string: "https://nas.local:8443/x")!
      ),
      "端口不同不同源"
    )
    expect(
      !WebDAVOrigin.isSameOrigin(
        URL(string: "https://nas.local/x")!, URL(string: "https://evil.example/x")!
      ),
      "主机不同不同源"
    )
    expect(
      !WebDAVOrigin.isSameOrigin(
        URL(string: "file:///etc/passwd")!, URL(string: "https://nas.local/x")!
      ),
      "file 协议永不与 HTTP 同源"
    )

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
    let logs = [
      ReadingLogEntity(day: "2024-01-01", pages: 50),
      ReadingLogEntity(day: "2026-10-25", pages: 10),
      ReadingLogEntity(day: "2026-10-26", pages: 20),
      ReadingLogEntity(day: "2026-10-26", pages: 5),
      ReadingLogEntity(day: "2026-10-27", pages: 0),
      ReadingLogEntity(day: "2026-10-28", pages: 500)
    ]
    let stats = Queries.stats(logs: logs, now: date, calendar: calendar)
    expect(stats.totalPages == 85, "累计页数包含一年前的流水，忽略未来与零页记录")
    expect(stats.totalDays == 3, "同一天多条流水只记一个阅读日")
    expect(stats.streak == 2, "今天未读不应中断昨天的连续记录")
    expect(stats.days["2026-10-26"] == 25, "同日流水合并")
    expect(Queries.stats(logs: [], now: date, calendar: calendar).streak == 0, "空数据连续天数为零")
    expect(WebDAVAddress.parse("nas.local/comics")?.absoluteString == "https://nas.local/comics", "无协议地址补全 HTTPS")
    expect(WebDAVAddress.parse(" http://192.168.1.8:8080/dav/ ") != nil, "支持局域网 HTTP 与自定义端口")
    for value in ["", "https://", "ftp://nas.local", "https://nas.local/#chapter", "https://user:secret@nas.local"] {
      expect(WebDAVAddress.parse(value) == nil, "拒绝无效地址或嵌入凭证：\(value)")
    }
    print("Passed \(checks) Yudu query and WebDAV checks")
  }
}
