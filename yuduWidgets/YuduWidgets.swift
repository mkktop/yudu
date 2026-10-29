import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 扫描进度 Live Activity（灵动岛/锁屏；属性结构须与 App 内 yudu/Core/ScanLiveActivity.swift 保持一致）

struct ScanActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var current: Int
    var total: Int
    var title: String
  }
  var libraryName: String
}

struct ScanActivityWidget: Widget {
  private func counter(_ state: ScanActivityAttributes.ContentState) -> String {
    state.total > 0 ? "\(min(state.current + 1, state.total))/\(state.total)" : "…"
  }

  var body: some WidgetConfiguration {
    ActivityConfiguration(for: ScanActivityAttributes.self) { context in
      HStack(spacing: 10) {
        Image(systemName: "book.pages")
          .font(.title3)
          .foregroundStyle(.purple)
        VStack(alignment: .leading, spacing: 2) {
          Text("雨读 · 扫描 \(context.attributes.libraryName)")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
          Text(context.state.title)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Text(counter(context.state))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(14)
      .activityBackgroundTint(Color(red: 0.16, green: 0.10, blue: 0.28))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: "book.pages")
            .foregroundStyle(.purple)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(alignment: .leading, spacing: 2) {
            Text("扫描：\(context.attributes.libraryName)")
              .font(.caption.weight(.semibold))
              .lineLimit(1)
            Text(context.state.title)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.trailing) {
          Text(counter(context.state))
            .font(.caption.monospacedDigit())
        }
        DynamicIslandExpandedRegion(.bottom) {
          if context.state.total > 0 {
            ProgressView(value: Double(context.state.current + 1), total: Double(max(context.state.total, 1)))
              .tint(.purple)
          }
        }
      } compactLeading: {
        Image(systemName: "book.pages")
          .foregroundStyle(.purple)
      } compactTrailing: {
        Text(counter(context.state))
          .font(.caption2.monospacedDigit())
      } minimal: {
        Image(systemName: "book.pages")
          .foregroundStyle(.purple)
      }
    }
  }
}

@main
struct YuduWidgetsBundle: WidgetBundle {
  var body: some Widget {
    ScanActivityWidget()
  }
}
