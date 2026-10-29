import ActivityKit
import Foundation

/// 扫描进度的灵动岛/锁屏 Live Activity（渲染在 yuduWidgets 扩展，属性结构须保持一致）
nonisolated struct ScanActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var current: Int
    var total: Int
    var title: String
  }
  var libraryName: String
}

@MainActor
enum ScanLiveActivity {
  static func begin(libraryName: String) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    // 清掉上次异常退出残留的活动
    for activity in Activity<ScanActivityAttributes>.activities {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
    let attributes = ScanActivityAttributes(libraryName: libraryName)
    let state = ScanActivityAttributes.ContentState(current: 0, total: 0, title: "正在读取云端目录")
    _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
  }

  static func update(current: Int, total: Int, title: String) {
    guard let activity = Activity<ScanActivityAttributes>.activities.first else { return }
    let state = ScanActivityAttributes.ContentState(current: current, total: total, title: title)
    Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
  }

  static func finish() {
    for activity in Activity<ScanActivityAttributes>.activities {
      let state = ScanActivityAttributes.ContentState(current: 1, total: 1, title: "扫描完成")
      Task {
        await activity.end(
          ActivityContent(state: state, staleDate: nil),
          dismissalPolicy: .after(.now.addingTimeInterval(4))
        )
      }
    }
  }
}
