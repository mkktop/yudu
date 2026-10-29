import Foundation

/// 从章节文件名解析卷号 / 话号（移植桌面版 scanner/parse.ts 的规则）
nonisolated enum FilenameParser {

  struct Parsed {
    var volume: String?
    var number: Double?
    var cleanTitle: String
  }

  static func parseChapter(_ rawName: String) -> Parsed {
    // 去扩展名，统一分隔符
    var name = MediaSniff.stemOf(rawName)
      .replacingOccurrences(of: "_", with: " ")

    // 去掉开头最多两组汉化组/来源括号 [组名] {组名} (组名)
    for _ in 0..<2 {
      if let range = name.range(of: #"^\s*(?:\[[^\]]*\]|\{[^}]*\}|\([^)]*\))\s*[-_·・]?\s*"#, options: .regularExpression) {
        name = String(name[range.upperBound...])
      } else {
        break
      }
    }

    let volume = firstString(name, patterns: [
      #"第\s*(\d{1,4}(?:\.\d+)?)\s*[卷巻冊]"#,
      #"(?i)\bvol(?:ume)?\.?\s*(\d{1,4})"#,
      #"(?i)\bv\.?(\d{1,4})\b"#,
    ])

    var number = firstDouble(name, patterns: [
      #"第\s*(\d{1,4}(?:\.\d+)?)\s*[话話回]"#,
      #"(?i)\b(?:chap|chapter)\.?\s*(\d{1,4}(?:\.\d+)?)"#,
      #"(?i)\bch\.?\s*(\d{1,4}(?:\.\d+)?)"#,
      #"(?i)\b(?:ep|episode)\.?\s*(\d{1,4}(?:\.\d+)?)"#,
      #"(?i)\bc(\d{1,4}(?:\.\d+)?)\b"#,
    ])

    // 没有显式话号时用结尾的独立数字兜底
    if number == nil {
      number = firstDouble(name, patterns: [#"(?:^|[\s.\-()【】\[\]])(\d{1,4}(?:\.\d+)?)\s*$"#])
    }
    // 话号缺失时回退卷号数值（对齐桌面版 parsedCh.number ?? parsedCh.volume）
    if number == nil { number = volume.flatMap(Double.init) }

    let cleanTitle = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return Parsed(volume: volume, number: number, cleanTitle: cleanTitle.isEmpty ? rawName : cleanTitle)
  }

  private static func firstCapture(_ name: String, patterns: [String]) -> String? {
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
            match.numberOfRanges > 1,
            let captured = Range(match.range(at: 1), in: name)
      else { continue }
      let text = String(name[captured]).filter { $0.isNumber || $0 == "." }
      if !text.isEmpty { return text }
    }
    return nil
  }

  private static func firstString(_ name: String, patterns: [String]) -> String? {
    firstCapture(name, patterns: patterns)
  }

  private static func firstDouble(_ name: String, patterns: [String]) -> Double? {
    firstCapture(name, patterns: patterns).flatMap(Double.init)
  }
}
