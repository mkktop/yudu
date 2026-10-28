import Foundation
import SwiftData

/// 轻量错误类型（Result 的 Failure 用）
struct Failure: Error, LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

// MARK: - 阅读偏好

enum ReaderMode: String, CaseIterable, Identifiable, Codable {
  case single
  case webtoon

  var id: String { rawValue }
  var label: String {
    switch self {
    case .single: "单页"
    case .webtoon: "条漫"
    }
  }
}

enum ReaderFit: String, CaseIterable, Identifiable, Codable {
  case width
  case height

  var id: String { rawValue }
  var label: String {
    switch self {
    case .width: "适宽"
    case .height: "适高"
    }
  }
}

/// 全局默认阅读偏好（设置页可改）
struct ReaderDefaults: Codable {
  var mode: ReaderMode = .single
  var rtl: Bool = true
  var fit: ReaderFit = .width

  static let storageKey = "readerDefaults"

  static func load(_ defaults: UserDefaults = .standard) -> ReaderDefaults {
    if let data = defaults.data(forKey: storageKey),
       let value = try? JSONDecoder().decode(ReaderDefaults.self, from: data) {
      return value
    }
    return ReaderDefaults()
  }

  func save(_ defaults: UserDefaults = .standard) {
    if let data = try? JSONEncoder().encode(self) {
      defaults.set(data, forKey: Self.storageKey)
    }
  }
}

/// 系列的有效阅读偏好 = 系列记忆值覆盖全局默认
struct EffectivePrefs {
  var mode: ReaderMode
  var rtl: Bool
  var fit: ReaderFit
}

// MARK: - 阅读器用的轻量值类型（避免跨线程持有模型对象）

struct ChapterRef: Identifiable, Equatable, Hashable {
  var id: PersistentIdentifier
  var path: String
  var title: String
  var kind: String
  var pageCount: Int
  var seriesKey: String
  var seriesTitle: String

  var isPDF: Bool { kind == "pdf" }
}

// MARK: - 查询服务（全部在主线程调用）

@MainActor
enum Queries {

  // MARK: 章节

  static func orderedChapters(_ series: SeriesEntity) -> [ChapterEntity] {
    (series.chapters).sorted { a, b in
      if a.sortIndex != b.sortIndex { return a.sortIndex < b.sortIndex }
      return a.persistentModelID.hashValue < b.persistentModelID.hashValue
    }
  }

  static func chaptersRef(_ series: SeriesEntity) -> [ChapterRef] {
    orderedChapters(series).map { ch in
      ChapterRef(
        id: ch.persistentModelID,
        path: ch.path,
        title: ch.title,
        kind: ch.kind,
        pageCount: ch.pageCount,
        seriesKey: series.key,
        seriesTitle: series.title
      )
    }
  }

  static func ref(_ chapter: ChapterEntity) -> ChapterRef {
    ChapterRef(
      id: chapter.persistentModelID,
      path: chapter.path,
      title: chapter.title,
      kind: chapter.kind,
      pageCount: chapter.pageCount,
      seriesKey: chapter.series?.key ?? "",
      seriesTitle: chapter.series?.title ?? ""
    )
  }

  /// 桌面版同款“继续阅读”规则：最近在读未读完 → 第一话未读完 → 最后一话
  static func continueTarget(_ series: SeriesEntity) -> ChapterEntity? {
    let chapters = orderedChapters(series)
    guard !chapters.isEmpty else { return nil }

    if let inProgress = chapters
      .filter({ $0.progress != nil && $0.progress?.completed == false })
      .max(by: { ($0.progress?.updatedAt ?? .distantPast) < ($1.progress?.updatedAt ?? .distantPast) }) {
      return inProgress
    }
    if let firstUnfinished = chapters.first(where: { $0.progress?.completed != true }) {
      return firstUnfinished
    }
    return chapters.last
  }

  /// 进入时落在哪一页：读完（或停在末页）则从头，否则停在进度页
  static func resumePage(_ chapter: ChapterEntity) -> Int {
    guard let p = chapter.progress else { return 0 }
    if p.completed { return 0 }
    let count = max(chapter.pageCount, 1)
    if p.page >= count - 1 { return 0 }
    return min(max(p.page, 0), count - 1)
  }

  // MARK: 书架状态

  enum ShelfStatus {
    case unread
    case reading
    case finished
  }

  struct SeriesInfo {
    var series: SeriesEntity
    var total: Int
    var read: Int
    var status: ShelfStatus
    /// 0...1，未读完最多显示 0.99（对齐桌面版）
    var fraction: Double
  }

  static func info(_ series: SeriesEntity) -> SeriesInfo {
    let chapters = orderedChapters(series)
    let total = chapters.count
    let read = chapters.filter { $0.progress?.completed == true }.count
    let partial = chapters.filter { $0.progress != nil && $0.progress?.completed != true }
    let status: ShelfStatus
    if total > 0 && read == total {
      status = .finished
    } else if read > 0 || !partial.isEmpty {
      status = .reading
    } else {
      status = .unread
    }
    let partialFraction = partial.reduce(0.0) { sum, chapter in
      guard chapter.pageCount > 0, let progress = chapter.progress else { return sum }
      return sum + min(Double(progress.page + 1) / Double(chapter.pageCount), 0.99)
    }
    let fraction = total == 0 ? 0 : min((Double(read) + partialFraction) / Double(total), read == total ? 1 : 0.99)
    return SeriesInfo(series: series, total: total, read: read, status: status, fraction: fraction)
  }

  // MARK: 首页继续阅读

  struct ContinueItem: Identifiable {
    var id: PersistentIdentifier
    var series: SeriesEntity
    var chapter: ChapterEntity
    var page: Int
    var pageCount: Int
  }

  static func continueItems(_ seriesList: [SeriesEntity], limit: Int = 12) -> [ContinueItem] {
    let recent = seriesList
      .filter { $0.lastReadAt != nil && info($0).status == .reading }
      .sorted { ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast) }
    return Array(recent.compactMap { series -> ContinueItem? in
      guard let chapter = continueTarget(series) else { return nil }
      return ContinueItem(
        id: series.persistentModelID, series: series, chapter: chapter,
        page: resumePage(chapter), pageCount: chapter.pageCount
      )
    }.prefix(max(limit, 0)))
  }

  // MARK: 偏好

  static func prefs(for series: SeriesEntity, context: ModelContext) -> EffectivePrefs {
    let defaults = ReaderDefaults.load()
    let stored = Self.seriesPrefs(series.key)
    return EffectivePrefs(
      mode: stored?.mode ?? defaults.mode,
      rtl: stored?.rtl ?? defaults.rtl,
      fit: stored?.fit ?? defaults.fit
    )
  }

  // MARK: 系列偏好（UserDefaults，小数据读写零风险）

  private struct StoredSeriesPrefs: Codable {
    var mode: ReaderMode?
    var rtl: Bool?
    var fit: ReaderFit?
  }

  private static func seriesPrefsStorageKey(_ seriesKey: String) -> String {
    "seriesPrefs." + seriesKey
  }

  private static func seriesPrefs(_ seriesKey: String, defaults: UserDefaults = .standard) -> StoredSeriesPrefs? {
    guard let data = defaults.data(forKey: seriesPrefsStorageKey(seriesKey)) else { return nil }
    return try? JSONDecoder().decode(StoredSeriesPrefs.self, from: data)
  }

  static func savePrefs(seriesKey: String, context: ModelContext,
                        mode: ReaderMode? = nil, rtl: Bool? = nil, fit: ReaderFit? = nil) {
    var stored = seriesPrefs(seriesKey) ?? StoredSeriesPrefs()
    if let mode { stored.mode = mode }
    if let rtl { stored.rtl = rtl }
    if let fit { stored.fit = fit }
    if let data = try? JSONEncoder().encode(stored) {
      UserDefaults.standard.set(data, forKey: seriesPrefsStorageKey(seriesKey))
    }
  }

  // MARK: 进度写入

  static func writeProgress(chapter: ChapterEntity, page: Int, context: ModelContext) {
    let count = chapter.pageCount
    var completed = false
    if count > 0, page >= count - 1 { completed = true }

    let delta: Int
    if let p = chapter.progress {
      delta = max(page - p.page, 0)
      p.page = page
      p.completed = completed
      p.updatedAt = .now
    } else {
      delta = page + 1
      let p = ProgressEntity(page: page, completed: completed, updatedAt: .now)
      p.chapter = chapter
      context.insert(p)
    }
    chapter.series?.lastReadAt = .now

    if delta > 0 {
      context.insert(ReadingLogEntity(day: Self.dayKey(.now), pages: delta))
    }
    try? context.save()
  }

  static func setCompleted(_ chapter: ChapterEntity, completed: Bool, context: ModelContext) {
    if completed {
      let p: ProgressEntity
      if let existing = chapter.progress {
        p = existing
      } else {
        p = ProgressEntity(updatedAt: .now)
        p.chapter = chapter
        context.insert(p)
      }
      p.completed = true
      p.updatedAt = .now
      if chapter.pageCount > 0 { p.page = chapter.pageCount - 1 }
    } else if let p = chapter.progress {
      chapter.progress = nil
      context.delete(p)
    }
    chapter.series?.lastReadAt = .now
    try? context.save()
  }

  static func markAllRead(_ series: SeriesEntity, context: ModelContext) {
    for chapter in orderedChapters(series) {
      setCompleted(chapter, completed: true, context: context)
    }
  }

  static func resetProgress(_ series: SeriesEntity, context: ModelContext) {
    for chapter in series.chapters {
      if let p = chapter.progress {
        chapter.progress = nil
        context.delete(p)
      }
    }
    series.lastReadAt = nil
    try? context.save()
  }

  // MARK: 统计

  struct StatsSummary {
    var days: [String: Int]
    var streak: Int
    var totalPages: Int
    var totalDays: Int
  }

  /// 累计指标使用完整流水；时间范围只影响统计页热力图。
  static func stats(context: ModelContext) -> StatsSummary {
    stats(logs: (try? context.fetch(FetchDescriptor<ReadingLogEntity>())) ?? [])
  }

  static func stats(logs: [ReadingLogEntity], now: Date = .now, calendar: Calendar = .current) -> StatsSummary {
    var byDay: [String: Int] = [:]
    let today = dayKey(now, locale: calendar)
    for log in logs where log.pages > 0 && log.day <= today {
      byDay[log.day, default: 0] += log.pages
    }
    var streak = 0
    var cursor = calendar.startOfDay(for: now)
    if byDay[dayKey(cursor, locale: calendar)] == nil {
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
    }
    while byDay[dayKey(cursor, locale: calendar)] != nil {
      streak += 1
      guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
      cursor = previous
    }
    return StatsSummary(days: byDay, streak: streak, totalPages: byDay.values.reduce(0, +), totalDays: byDay.count)
  }

  static func dayKey(_ date: Date, locale calendar: Calendar = .current) -> String {
    let comps = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
  }
}
