import Foundation
import CoreGraphics
import CryptoKit

/// 每章页尺寸持久化（只存宽高，几 KB）。
/// 条漫续读定位和二次打开不再为拿尺寸重新下载/探测。
nonisolated final class PageDimsStore: @unchecked Sendable {
  static let shared = PageDimsStore()

  private let dir: URL

  private init() {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    dir = caches.appendingPathComponent("page-dims", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  private func fileURL(sourceID: String) -> URL {
    let hash = SHA256.hash(data: Data(sourceID.utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
    return dir.appendingPathComponent(hash + ".json")
  }

  func load(sourceID: String) -> [Int: CGSize] {
    guard !sourceID.isEmpty,
          let data = try? Data(contentsOf: fileURL(sourceID: sourceID)),
          let raw = try? JSONDecoder().decode([String: [Double]].self, from: data)
    else { return [:] }
    var result: [Int: CGSize] = [:]
    for (key, value) in raw where value.count >= 2 && value[0] > 0 && value[1] > 0 {
      if let index = Int(key) {
        result[index] = CGSize(width: value[0], height: value[1])
      }
    }
    return result
  }

  func save(sourceID: String, dims: [Int: CGSize]) {
    guard !sourceID.isEmpty, !dims.isEmpty else { return }
    var raw: [String: [Double]] = [:]
    for (index, size) in dims where size.width > 0 && size.height > 0 {
      raw[String(index)] = [Double(size.width), Double(size.height)]
    }
    guard let data = try? JSONEncoder().encode(raw) else { return }
    try? data.write(to: fileURL(sourceID: sourceID), options: .atomic)
  }
}
