import Foundation

/// 阅读活动门：阅读器打开期间暂停云端扫描 / 封面生成。
/// 天翼的 300ms 接口节流是全局的，扫描和翻页会互相拖慢；阅读优先。
@MainActor
enum ReaderActivity {
  private static var readers = 0

  static var isReading: Bool { readers > 0 }

  static func begin() { readers += 1 }

  static func end() { readers = max(0, readers - 1) }

  /// 扫描 / 封面任务在每次网络请求前调用；阅读器打开时挂起等待。
  static func waitWhileReading() async {
    while isReading {
      try? await Task.sleep(for: .milliseconds(300))
    }
  }
}
