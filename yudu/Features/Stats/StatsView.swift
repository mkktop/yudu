import SwiftUI
import SwiftData

struct StatsView: View {
  @Environment(\.modelContext) private var context

  @State private var summary: Queries.StatsSummary?
  @State private var range: HeatRange = .halfYear

  enum HeatRange: String, CaseIterable, Identifiable {
    case halfYear = "近半年"
    case year = "近一年"

    var id: String { rawValue }
    var weeks: Int { self == .halfYear ? 26 : 53 }
  }

  var body: some View {
    NavigationStack {
      Group {
        if let summary {
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              heroCard(summary)
              metricCards(summary)
              heatmap(summary)
            }
            .padding(16)
          }
        } else {
          ProgressView()
        }
      }
      .navigationTitle("统计")
      .background(Color(.systemGroupedBackground))
    }
    .task {
      summary = Queries.stats(context: context)
    }
  }

  // MARK: - 连续阅读主卡

  private func heroCard(_ summary: Queries.StatsSummary) -> some View {
    let todayPages = summary.days[Queries.dayKey(.now)] ?? 0
    return HStack(alignment: .center, spacing: 14) {
      Image(systemName: "flame.fill")
        .font(.system(size: 34))
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 64, height: 64)
        .background(.white.opacity(0.16), in: Circle())

      VStack(alignment: .leading, spacing: 3) {
        Text("\(summary.streak) 天")
          .font(.system(size: 30, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("连续阅读")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.75))
      }

      Spacer()

      if todayPages > 0 {
        VStack(spacing: 2) {
          Text("\(todayPages)")
            .font(.title3.weight(.bold).monospacedDigit())
          Text("今日页")
            .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [Color.cinnabar, Color(hex: 0x8F2F1F)],
        startPoint: .topLeading, endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: 18)
    )
    .shadow(color: Color.cinnabar.opacity(0.35), radius: 10, y: 5)
  }

  // MARK: - 指标卡

  private func metricCards(_ summary: Queries.StatsSummary) -> some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      StatCard(title: "累计翻页", value: summary.totalPages.formatted(), icon: "book.pages.fill")
      StatCard(title: "阅读天数", value: "\(summary.totalDays)", icon: "calendar")
    }
  }

  // MARK: - 热力图

  private func heatmap(_ summary: Queries.StatsSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("阅读热力")
          .font(.headline)
        Spacer()
        Picker("范围", selection: $range) {
          ForEach(HeatRange.allCases) { range in
            Text(range.rawValue).tag(range)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 168)
      }

      let weeks = Self.weekBuckets(summary.days, weeks: range.weeks)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 10) {
          // 星期标签（周日起）
          VStack(alignment: .trailing, spacing: 2.5) {
            ForEach(0..<7, id: \.self) { day in
              Text(Self.weekdayLabel(day))
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
                .frame(height: 11)
            }
          }
          HStack(spacing: 2.5) {
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
              VStack(spacing: 2.5) {
                ForEach(0..<7, id: \.self) { day in
                  if let cell = week.first(where: { $0.weekday == day }) {
                    RoundedRectangle(cornerRadius: 2)
                      .fill(cell.color)
                      .frame(width: 11, height: 11)
                  } else {
                    Color.clear.frame(width: 11, height: 11)
                  }
                }
              }
            }
          }
        }
        .padding(1)
      }

      HStack(spacing: 6) {
        Text("按天计页，颜色越深读得越多")
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Spacer()
        Text("少")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        ForEach(0...4, id: \.self) { level in
          RoundedRectangle(cornerRadius: 2)
            .fill(Self.levelColor(level))
            .frame(width: 10, height: 10)
        }
        Text("多")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
  }

  // MARK: - 数据

  struct HeatCell: Hashable {
    var weekday: Int
    var level: Int

    var color: Color { StatsView.levelColor(level) }
  }

  /// 生成按周分列的热力图格子（列 = 周，行 = 周日…周六），取最近 N 周
  static func weekBuckets(_ days: [String: Int], weeks targetWeeks: Int) -> [[HeatCell]] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let weekdayToday = calendar.component(.weekday, from: today) // 1=周日

    // 从 targetWeeks-1 周前的周日开始
    let daysBack = 7 * (targetWeeks - 1) + (weekdayToday - 1)
    guard let start = calendar.date(byAdding: .day, value: -daysBack, to: today) else { return [] }

    var weeks: [[HeatCell]] = []
    var current: [HeatCell] = []
    var cursor = start
    while cursor <= today {
      let key = Queries.dayKey(cursor)
      let pages = days[key] ?? 0
      let weekday = calendar.component(.weekday, from: cursor)
      current.append(HeatCell(weekday: weekday, level: level(pages)))
      if weekday == 7 {
        weeks.append(current)
        current = []
      }
      cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? today
      if cursor > today { break }
    }
    if !current.isEmpty {
      weeks.append(current)
    }
    return weeks
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
    case 0: Color(.systemFill)
    case 1: Color.cinnabar.opacity(0.28)
    case 2: Color.cinnabar.opacity(0.5)
    case 3: Color.cinnabar.opacity(0.75)
    default: Color.cinnabar
    }
  }

  static func weekdayLabel(_ weekday: Int) -> String {
    // weekday 1=周日；只标一、四、六，其余留空
    switch weekday {
    case 1: "日"
    case 2: ""
    case 3: ""
    case 4: "三"
    case 5: ""
    case 6: ""
    default: "六"
    }
  }
}

private struct StatCard: View {
  let title: String
  let value: String
  let icon: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.cinnabar)
        .frame(width: 42, height: 42)
        .background(Color.cinnabar.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
      VStack(alignment: .leading, spacing: 2) {
        Text(value)
          .font(.title2.weight(.bold).monospacedDigit())
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.6)
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
  }
}
