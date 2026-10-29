import Foundation
import CryptoKit

/// 扫描力度：增量扫描只复查远端有变化的目录，完整扫描忽略缓存。
nonisolated enum LibraryScanMode: Sendable {
  case incremental
  case full

  var label: String { self == .full ? "完整" : "增量" }
}

/// 单个散图子目录的页数缓存：目录指纹没变就不必再列一次目录。
nonisolated struct CachedFolderPages: Codable {
  var fingerprint: String
  var pageCount: Int
  /// 目录里是否有漫画内容（图片/压缩包/PDF）；天翼用它判断“卷文件夹”。
  var hasMedia: Bool
}

/// 书库根目录下一个子项（系列文件夹 / 散装压缩包）上次扫描的结果。
nonisolated struct CachedChildScan: Codable {
  /// 远端指纹：id/地址 + 名称 + 大小 + 修改时间；任何一项变化都要重扫。
  var fingerprint: String
  /// cloud189: volume / wrapper / series；WebDAV: series。散装压缩包统一为 archive。
  var kind: String
  /// 多系列布局下这个子项对应的作品
  var series: ScannedSeries?
  /// 单系列布局下这个子项贡献的章节
  var chapters: [ScannedChapter]
  /// 子目录页数缓存（键为 fileId 或 URL 字符串）
  var folderPages: [String: CachedFolderPages]
  var complete: Bool
  var scannedAt: Date
  /// 远端没提供修改时间时指纹不可靠，只在短时间内复用。
  var volatile: Bool
}

/// 增量扫描缓存：按书库保存根目录子项的指纹与上次扫描结果。
/// 只要远端目录没变，重扫时就不必逐层下钻。
nonisolated enum ScanCache {
  private static let version = 2
  /// 没有修改时间的目录，最多复用 10 分钟，避免长期看不到新章节。
  private static let volatileTTL: TimeInterval = 10 * 60

  private struct Snapshot: Codable {
    var version: Int
    var entries: [String: CachedChildScan]
  }

  static func load(libraryKey: String) -> [String: CachedChildScan] {
    guard let data = try? Data(contentsOf: fileURL(libraryKey)),
          let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
          snapshot.version == version
    else { return [:] }
    return snapshot.entries
  }

  static func save(_ entries: [String: CachedChildScan], libraryKey: String) {
    let snapshot = Snapshot(version: version, entries: entries)
    guard let data = try? JSONEncoder().encode(snapshot) else { return }
    let url = fileURL(libraryKey)
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try? data.write(to: url, options: .atomic)
  }

  static func clear(libraryKey: String) {
    try? FileManager.default.removeItem(at: fileURL(libraryKey))
  }

  /// 指纹相同、扫描完整，且（必要时）还在短期有效期内，才算命中。
  static func canReuse(_ entry: CachedChildScan, fingerprint: String, mode: LibraryScanMode) -> Bool {
    guard mode == .incremental, entry.complete, entry.fingerprint == fingerprint else { return false }
    guard entry.volatile else { return true }
    return Date.now.timeIntervalSince(entry.scannedAt) < volatileTTL
  }

  private static func fileURL(_ libraryKey: String) -> URL {
    let digest = SHA256.hash(data: Data(libraryKey.utf8))
    let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return caches
      .appendingPathComponent("scan-cache", isDirectory: true)
      .appendingPathComponent(name + ".json")
  }
}
