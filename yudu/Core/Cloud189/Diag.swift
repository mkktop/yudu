import Foundation

/// 天翼登录排障日志：Debug 构建写 Documents/cloud189-diag.log，
/// 用 `xcrun devicectl device copy from --domain-type appDataContainer` 拉取分析。
#if DEBUG
nonisolated enum Diag {
  private static let lock = NSLock()

  static func log(_ text: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(text)\n"
    lock.lock()
    defer { lock.unlock() }
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("cloud189-diag.log")
    var data = (try? Data(contentsOf: url)) ?? Data()
    if data.count > 96 * 1024 { data = Data(data.suffix(48 * 1024)) }
    data.append(Data(line.utf8))
    try? data.write(to: url)
  }
}
#else
nonisolated enum Diag {
  static func log(_ text: String) {}
}
#endif
