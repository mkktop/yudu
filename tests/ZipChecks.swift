import Foundation

/// 在 macOS 上验证 ZIP 解析器的健壮性：合法压缩包可读、畸形文件必须抛错而不是崩溃。
@main
struct ZipChecks {
  static func main() throws {
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      precondition(condition(), message)
      checks += 1
    }
    func expectThrows(_ message: String, _ body: () throws -> Void) {
      do {
        try body()
        precondition(false, message)
      } catch {
        checks += 1
      }
    }

    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("yudu-zipchecks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ bytes: [UInt8]) throws -> URL {
      let url = dir.appendingPathComponent(name)
      try Data(bytes).write(to: url)
      return url
    }

    // 1. 合法 store zip：条目数、自然排序、数据原样读回
    let pageA = Array("page-A-image-bytes".utf8)
    let pageB = Array("page-b-image-bytes".utf8)
    let valid = try buildStoreZip(
      name: "valid.zip",
      entries: [("002.png", pageB), ("001.png", pageA)],
      lhoOverride: nil
    )
    let zip = try ZipFile(url: valid)
    expect(zip.pageCount == 2, "合法 zip 应解析出两个页面条目")
    expect(zip.entries[0].name == "001.png" && zip.entries[1].name == "002.png", "条目必须按自然排序")
    expect(zip.entryData(at: 0) == Data(pageA), "store 条目应原样读回")
    expect(zip.entryData(at: 1) == Data(pageB), "第二个条目应原样读回")

    // 2. zip64 头写满超大值：必须抛错而不是 Int 转换 trap
    expectThrows("zip64 超大 entryCount 必须抛错") {
      _ = try ZipFile(url: try write("zip64-count.zip", craftedZip64HugeCount()))
    }
    // 3. 中央目录大小溢出：必须抛错
    expectThrows("zip64 超大 centralSize 必须抛错") {
      _ = try ZipFile(url: try write("zip64-size.zip", craftedZip64HugeCentralSize()))
    }
    // 4. 本地头偏移越界：解析可以成功，取页必须返回 nil 而不是崩溃
    let badOffset = try buildStoreZip(
      name: "bad-offset.zip",
      entries: [("001.png", pageA)],
      lhoOverride: 0x7FFF_FFFF
    )
    let badOffsetZip = try ZipFile(url: badOffset)
    expect(badOffsetZip.pageCount == 1, "坏偏移 zip 仍应解析出条目")
    expect(badOffsetZip.entryData(at: 0) == nil, "本地头越界必须返回 nil")
    expectThrows("超长本地头必须抛错") {
      _ = try ZipFile(url: try write("not-zip.zip", Array("plain text file".utf8)))
    }

    // 5. 文件名解析
    let chapter = FilenameParser.parseChapter("[汉化组] 风起 第12话.cbz")
    expect(chapter.number == 12, "「第12话」应解析出话号")
    expect(chapter.volume == nil, "没有卷号标记时卷号为空")
    let volume = FilenameParser.parseChapter("第3卷 c045.zip")
    expect(volume.volume == "3", "「第3卷」解析卷号")
    expect(volume.number == 45, "「c045」解析话号")
    expect(FilenameParser.parseChapter("episode 7").number == 7, "英文 ep 标记解析")
    expect(naturalCompare("第2话", "第10话"), "自然排序：第2话在第10话前")
    expect(!naturalCompare("第10话", "第10话"), "相同标题不判为更小")

    print("Passed \(checks) Yudu zip and parser checks")
  }

  // MARK: - 测试压缩包构造

  struct ZipEntry {
    let name: [UInt8]
    let crc: UInt32
    let size: UInt32
    let lho: UInt32
  }

  static func buildStoreZip(name: String, entries: [(String, [UInt8])], lhoOverride: UInt32?) throws -> URL {
    var out: [UInt8] = []
    var centrals: [ZipEntry] = []
    for (entryName, payload) in entries {
      let nameBytes = Array(entryName.utf8)
      let lho = lhoOverride ?? UInt32(out.count)
      out += [0x50, 0x4B, 0x03, 0x04]
      out += u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
      out += u32(crc32(payload)) + u32(UInt32(payload.count)) + u32(UInt32(payload.count))
      out += u16(UInt16(nameBytes.count)) + u16(0)
      out += nameBytes + payload
      centrals.append(
        ZipEntry(name: nameBytes, crc: crc32(payload), size: UInt32(payload.count), lho: lho)
      )
    }
    let centralStart = UInt32(out.count)
    for entry in centrals {
      out += [0x50, 0x4B, 0x01, 0x02]
      out += u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
      out += u32(entry.crc) + u32(entry.size) + u32(entry.size)
      out += u16(UInt16(entry.name.count)) + u16(0) + u16(0)
      out += u16(0) + u16(0) + u32(0) + u32(entry.lho)
      out += entry.name
    }
    out += [0x50, 0x4B, 0x05, 0x06]
    out += u16(0) + u16(0) + u16(UInt16(centrals.count)) + u16(UInt16(centrals.count))
    out += u32(UInt32(out.count) - centralStart) + u32(centralStart) + u16(0)

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("yudu-\(name)-\(UUID().uuidString)")
    try Data(out).write(to: url)
    return url
  }

  /// zip64 EOCD 声称 entryCount = UInt64.max（200 字节的假文件）
  static func craftedZip64HugeCount() -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 200)
    data.replaceSubrange(0..<46, with: centralDirectoryHeader())
    var z64: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
    z64 += u64(44) + u16(45) + u16(45) + u32(0) + u32(0)
    z64 += u64(1) + u64(UInt64.max) + u64(46) + u64(0)
    data.replaceSubrange(46..<(46 + z64.count), with: z64)
    let loc: [UInt8] = [0x50, 0x4B, 0x06, 0x07] + u32(0) + u64(46) + u32(1)
    data.replaceSubrange(102..<(102 + loc.count), with: loc)
    var tail: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + u16(0) + u16(0) + u16(0xFFFF) + u16(0xFFFF)
    tail += u32(0xFFFF_FFFF) + u32(0xFFFF_FFFF) + u16(0)
    data.replaceSubrange(122..<(122 + tail.count), with: tail)
    return data
  }

  /// zip64 EOCD 声称 centralSize = UInt64.max
  static func craftedZip64HugeCentralSize() -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 200)
    data.replaceSubrange(0..<46, with: centralDirectoryHeader())
    var z64: [UInt8] = [0x50, 0x4B, 0x06, 0x06]
    z64 += u64(44) + u16(45) + u16(45) + u32(0) + u32(0)
    z64 += u64(1) + u64(1) + u64(UInt64.max) + u64(0)
    data.replaceSubrange(46..<(46 + z64.count), with: z64)
    let loc: [UInt8] = [0x50, 0x4B, 0x06, 0x07] + u32(0) + u64(46) + u32(1)
    data.replaceSubrange(102..<(102 + loc.count), with: loc)
    var tail: [UInt8] = [0x50, 0x4B, 0x05, 0x06] + u16(0) + u16(0) + u16(0xFFFF) + u16(0xFFFF)
    tail += u32(0xFFFF_FFFF) + u32(0xFFFF_FFFF) + u16(0)
    data.replaceSubrange(122..<(122 + tail.count), with: tail)
    return data
  }

  private static func centralDirectoryHeader() -> [UInt8] {
    var cd: [UInt8] = [0x50, 0x4B, 0x01, 0x02]
    cd += u16(20) + u16(0) + u16(0) + u16(0) + u16(0) + u16(0)
    cd += u32(0) + u32(0) + u32(0)
    cd += u16(0) + u16(0) + u16(0)
    cd += u16(0) + u16(0) + u32(0) + u32(0)
    return cd
  }

  private static func u16(_ v: UInt16) -> [UInt8] {
    [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]
  }

  private static func u32(_ v: UInt32) -> [UInt8] {
    (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) }
  }

  private static func u64(_ v: UInt64) -> [UInt8] {
    (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) }
  }

  private static func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
      crc ^= UInt32(byte)
      for _ in 0..<8 {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
      }
    }
    return crc ^ 0xFFFF_FFFF
  }
}
