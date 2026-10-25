import SwiftUI
import SwiftData

struct StatsView: View {
  @Environment(\.modelContext) private var context

  @State private var summary: Queries.StatsSummary?

  var body: some View {
    NavigationStack {
      Group {
        if let summary {
          ScrollView {
            VStack(alignment: .leading, spacing: 20) {
              cards(summary)
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

  // MARK: - 指标卡

  private func cards(_ summary: Queries.StatsSummary) -> some View {
    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
      StatCard(title: "连续", value: "\(summary.streak) 天", icon: "flame.fill")
      StatCard(title: "累计", value: "\(summary.totalPages) 页", icon: "book.pages.fill")
      StatCard(title: "阅读天数", value: "\(summary.totalDays) 天", icon: "calendar")
    }
  }

  // MARK: - 热力图

  private func heatmap(_ summary: Queries.StatsSummary) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("最近一年")
        .font(.headline)

      let weeks = Self.weekBuckets(summary.days)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 10) {
          // 星期标签（周日起）
          VStack(alignment: .trailing, spacing: 2) {
            ForEach(0..<7, id: \.self) { day in
              Text(Self.weekdayLabel(day))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(height: 12)
            }
          }
          HStack(spacing: 3) {
            ForEach(weeks, id: \.self) { week in
              VStack(spacing: 3) {
                ForEach(0..<7, id: \.self) { day in
                  if let cell = week.first(where: { $0.weekday == day }) {
                    RoundedRectangle(cornerRadius: 2.5)
                      .fill(cell.color)
                      .frame(width: 12, height: 12)
                  } else {
                    Color.clear.frame(width: 12, height: 12)
                  }
                }
              }
            }
          }
        }
        .padding(2)
      }

      HStack(spacing: 6) {
        Spacer()
        Text("少")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
        ForEach(0...4, id: \.self) { level in
          RoundedRectangle(cornerRadius: 2.5)
            .fill(Self.levelColor(level))
            .frame(width: 10, height: 10)
        }
        Text("多")
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
  }

  // MARK: - 数据

  struct HeatCell: Hashable {
    var weekday: Int
    var level: Int

    var color: Color { StatsView.levelColor(level) }
  }

  /// 生成按周分列的热力图格子（与 GitHub 一致：列 = 周，行 = 周日…周六）
  static func weekBuckets(_ days: [String: Int]) -> [[HeatCell]] {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let weekdayToday = calendar.component(.weekday, from: today) // 1=周日

    // 从 52 周前的周日开始
    let daysBack = 7 * 52 + (weekdayToday - 1)
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
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: icon)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.title3.weight(.semibold).monospacedDigit())
        .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
  }
}
