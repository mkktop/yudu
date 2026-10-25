import Foundation

enum MediaSniff {

  static let imageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif", "apng", "tif", "tiff",
  ]
  static let archiveExtensions: Set<String> = ["zip", "cbz"]
  static let pdfExtensions: Set<String> = ["pdf"]

  static func isImage(_ name: String) -> Bool {
    imageExtensions.contains(extensionOf(name))
  }

  static func isArchive(_ name: String) -> Bool {
    archiveExtensions.contains(extensionOf(name))
  }

  static func isPDF(_ name: String) -> Bool {
    pdfExtensions.contains(extensionOf(name))
  }

  static func extensionOf(_ name: String) -> String {
    (name as NSString).pathExtension.lowercased()
  }

  static func stemOf(_ name: String) -> String {
    ((name as NSString).deletingPathExtension as NSString).lastPathComponent
  }

  /// 章节种类：优先魔数嗅探（纠正伪装扩展名），目录则递归判定
  /// 返回 "folder" | "zip" | "pdf" | nil（不认识）
  static func chapterKind(url: URL) -> String? {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
    if isDir.boolValue { return "folder" }

    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 8)) ?? Data()
    if head.starts(with: [0x50, 0x4B]) { return "zip" }           // PK..
    if head.starts(with: Array("%PDF".utf8)) { return "pdf" }

    // 魔数不认识时退回扩展名
    let ext = extensionOf(url.lastPathComponent)
    if archiveExtensions.contains(ext) { return "zip" }
    if pdfExtensions.contains(ext) { return "pdf" }
    return nil
  }
}

/// 数字感知的自然排序（第2话 < 第10话）
func naturalCompare(_ a: String, _ b: String) -> Bool {
  a.compare(b, options: .numeric, locale: Locale(identifier: "zh_CN")) == .orderedAscending
}
