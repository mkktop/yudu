import SwiftUI
import SwiftData

struct StatsView: View {
  @Query private var logs: [ReadingLogEntity]
  @AppStorage("dailyReadingGoal") private var dailyGoal = 30
  @State private var range: HeatRange = .halfYear
  @State private var selectedDay = Queries.dayKey(.now)

  enum HeatRange: String, CaseIterable, Identifiable {
    case halfYear = "近半年", year = "近一年"
    var id: String { rawValue }
    var weeks: Int { self == .halfYear ? 26 : 53 }
  }
  private var summary: Queries.StatsSummary { Queries.stats(logs: logs) }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          SectionHeading(title: "每一页，都算数。", eyebrow: "READING SIGNAL")
          todayCard
          HStack(spacing: 12) {
            metric(title: "累计阅读", value: summary.totalPages.formatted(), unit: "页", icon: "book.pages")
            metric(title: "阅读天数", value: "\(summary.totalDays)", unit: "天", icon: "calendar")
          }
          weekChart
          heatmap
          if logs.isEmpty {
            NoticeView(title: "从第一话开始，点亮你的轨迹", message: "阅读时自动记录翻页。手动标记已读不会计入阅读页数。", icon: "sparkles")
          }
        }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("阅读统计")
      .navigationBarTitleDisplayMode(.inline)
    }
  }

  private var todayCard: some View {
    let pages = summary.days[Queries.dayKey(.now)] ?? 0
    let fraction = min(Double(pages) / Double(max(dailyGoal, 1)), 1)
    return HStack(spacing: 22) {
      ZStack {
        Circle().stroke(YuduTheme.elevated, lineWidth: 7)
        Circle().trim(from: 0, to: fraction)
          .stroke(YuduTheme.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
          .rotationEffect(.degrees(-90))
        VStack(spacing: 3) {
          Text("\(pages)").font(.system(size: 32, weight: .light, design: .rounded)).monospacedDigit()
          Text("今日已读 / 页").font(.system(size: 9)).foregroundStyle(YuduTheme.muted)
        }
      }.frame(width: 112, height: 112).accessibilityElement(children: .combine)
      VStack(alignment: .leading, spacing: 12) {
        StatusPill(text: pages >= dailyGoal ? "今日目标已达成" : "每日目标 \(dailyGoal) 页", icon: pages >= dailyGoal ? "checkmark" : "scope")
        Text("\(summary.streak) 天")
          .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
        Text("连续阅读").font(.caption).foregroundStyle(YuduTheme.muted)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(22).yuduPanel(accent: YuduTheme.accent)
  }

  private func metric(title: String, value: String, unit: String, icon: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(YuduTheme.violet)
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
        Text(unit).font(.caption).foregroundStyle(YuduTheme.muted)
      }
      Text(title).font(.caption).foregroundStyle(YuduTheme.muted)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(18).yuduPanel()
  }

  private var recentDays: [(date: Date, pages: Int)] {
    let calendar = Calendar.current
    return (-6...0).compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: offset, to: .now) else { return nil }
      return (date, summary.days[Queries.dayKey(date)] ?? 0)
    }
  }

  private var weekChart: some View {
    let days = recentDays
    let highest = max(days.map(\.pages).max() ?? 0, 1)
    return VStack(alignment: .leading, spacing: 20) {
      SectionHeading(title: "最近七天", eyebrow: "WEEKLY ACTIVITY", detail: "\(days.reduce(0) { $0 + $1.pages }) 页")
      HStack(alignment: .bottom, spacing: 12) {
        ForEach(Array(days.enumerated()), id: \.offset) { index, item in
          VStack(spacing: 8) {
            Text("\(item.pages)").font(.system(size: 10, design: .monospaced)).foregroundStyle(YuduTheme.muted)
            RoundedRectangle(cornerRadius: 5)
              .fill(index == 6 ? YuduTheme.accent : YuduTheme.violet.opacity(0.5))
              .frame(height: max(4, Double(item.pages) / Double(highest) * 85))
            Text(index == 6 ? "今天" : item.date.formatted(.dateTime.weekday(.narrow)))
              .font(.caption2).foregroundStyle(YuduTheme.muted)
          }
          .frame(maxWidth: .infinity)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(item.date.formatted(date: .abbreviated, time: .omitted))，阅读 \(item.pages) 页")
        }
      }.frame(height: 132, alignment: .bottom)
    }.padding(18).yuduPanel()
  }

  private var heatmap: some View {
    let weeks = Self.weekBuckets(summary.days, weeks: range.weeks)
    let selected = selectedInfo
    return VStack(alignment: .leading, spacing: 16) {
      SectionHeading(title: "阅读轨迹", eyebrow: "YOUR CONSTELLATION")
      Picker("热力图时间范围", selection: $range) {
        ForEach(HeatRange.allCases) { Text($0.rawValue).tag($0) }
      }.pickerStyle(.segmented)
      selectedDayCard(selected)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 4) {
          ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
            VStack(spacing: 4) {
              ForEach(0..<7, id: \.self) { day in
                if let cell = week.first(where: { $0.weekday == day }) {
                  Button {
                    selectedDay = cell.day
                  } label: {
                    RoundedRectangle(cornerRadius: 4)
                      .fill(Self.levelColor(cell.level))
                      .frame(width: 18, height: 18)
                      .overlay {
                        if selectedDay == cell.day {
                          RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(YuduTheme.text.opacity(0.9), lineWidth: 1.5)
                        }
                      }
                  }
                  .buttonStyle(.plain)
                  .accessibilityLabel(cell.pages > 0
                    ? "\(cell.day)，阅读 \(cell.pages) 页"
                    : "\(cell.day)，没有阅读")
                  .accessibilityAddTraits(selectedDay == cell.day ? .isSelected : [])
                } else {
                  Color.clear.frame(width: 18, height: 18).accessibilityHidden(true)
                }
              }
            }
          }
        }
        .padding(2)
      }
      .defaultScrollAnchor(.trailing)
      HStack(spacing: 6) {
        Text("点格子查看当天页数").font(.caption2).foregroundStyle(YuduTheme.muted)
        Spacer(minLength: 0)
        Text("少").font(.system(size: 9)).foregroundStyle(YuduTheme.muted)
        ForEach(0...4, id: \.self) { level in
          RoundedRectangle(cornerRadius: 2).fill(Self.levelColor(level)).frame(width: 11, height: 11)
        }
        Text("多").font(.system(size: 9)).foregroundStyle(YuduTheme.muted)
      }
    }
    .padding(18)
    .yuduPanel()
    .sensoryFeedback(.selection, trigger: selectedDay)
    .onChange(of: range) { _, _ in selectedDay = Queries.dayKey(.now) }
  }

  /// 当前选中日期的展示信息。
  private var selectedInfo: (title: String, pages: Int) {
    let pages = summary.days[selectedDay] ?? 0
    let title: String
    if let parts = Self.dayParts(selectedDay) {
      if selectedDay == Queries.dayKey(.now) {
        title = "今天 · \(parts.month)月\(parts.day)日"
      } else if parts.year == Calendar.current.component(.year, from: .now) {
        title = "\(parts.month)月\(parts.day)日 \(parts.weekday)"
      } else {
        title = "\(parts.year)年\(parts.month)月\(parts.day)日"
      }
    } else {
      title = selectedDay
    }
    return (title, pages)
  }

  private func selectedDayCard(_ info: (title: String, pages: Int)) -> some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 4)
        .fill(Self.levelColor(Self.level(info.pages)))
        .frame(width: 14, height: 14)
      Text(info.title).font(.subheadline.weight(.medium))
      Spacer(minLength: 8)
      Text(info.pages > 0 ? "\(info.pages) 页" : "没有阅读")
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .foregroundStyle(info.pages > 0 ? YuduTheme.accent : YuduTheme.muted)
    }
    .padding(.horizontal, 12)
    .frame(height: 42)
    .background(YuduTheme.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityElement(children: .combine)
    .animation(.easeOut(duration: 0.15), value: info.pages)
  }

  struct HeatCell: Hashable {
    var weekday: Int
    var level: Int
    var day: String
    var pages: Int
  }

  static func weekBuckets(_ days: [String: Int], weeks targetWeeks: Int) -> [[HeatCell]] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let daysBack = 7 * (max(targetWeeks, 1) - 1) + calendar.component(.weekday, from: today) - 1
    guard let start = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return [] }
    var weeks: [[HeatCell]] = []
    var current: [HeatCell] = []
    for offset in 0...daysBack {
      guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
      let key = Queries.dayKey(date)
      let pages = days[key] ?? 0
      let weekday = calendar.component(.weekday, from: date) - 1
      current.append(HeatCell(weekday: weekday, level: level(pages), day: key, pages: pages))
      if weekday == 6 { weeks.append(current); current = [] }
    }
    if !current.isEmpty { weeks.append(current) }
    return weeks
  }

  static func dayParts(_ key: String) -> (year: Int, month: Int, day: Int, weekday: String)? {
    let parts = key.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
          let date = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    else { return nil }
    let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    let index = Calendar.current.component(.weekday, from: date) - 1
    guard names.indices.contains(index) else { return nil }
    return (year, month, day, names[index])
  }

  static func level(_ pages: Int) -> Int {
    switch pages {
    case ..<1: 0
    case 1..<10: 1
    case 10..<30: 2
    case 30..<60: 3
    default: 4
    }
  }
  static func levelColor(_ level: Int) -> Color {
    switch level {
    case 0: YuduTheme.elevated
    case 1: YuduTheme.accent.opacity(0.22)
    case 2: YuduTheme.accent.opacity(0.45)
    case 3: YuduTheme.accent.opacity(0.7)
    default: YuduTheme.accent
    }
  }
}
