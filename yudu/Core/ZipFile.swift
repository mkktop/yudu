import Foundation
import Compression

/// 最小 ZIP 读取器（只读，本地文件）。
/// 覆盖常见 CBZ 场景：store/deflate、基本 zip64、伪装扩展名由魔数嗅探兜底。
/// 算法与桌面版 remoteZip.ts 一致：EOCD → 中央目录 → 本地头 → 按条目解压。
nonisolated final class ZipFile: @unchecked Sendable {

  struct Entry {
    let name: String
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    /// 0 = store, 8 = deflate
    let method: UInt16
    let localHeaderOffset: UInt64
  }

  enum ZipError: Error, LocalizedError {
    case notZip
    case corrupt(String)
    case unsupportedMethod(UInt16)
    case outOfMemory

    var errorDescription: String? {
      switch self {
      case .notZip: "不是有效的 ZIP 文件"
      case .corrupt(let why): "ZIP 结构损坏：\(why)"
      case .unsupportedMethod(let m): "不支持的压缩方式（\(m)），请用标准 ZIP/CBZ"
      case .outOfMemory: "文件过大"
      }
    }
  }

  let url: URL
  private let data: Data
  /// 按自然排序的图片条目
  let entries: [Entry]

  var pageCount: Int { entries.count }

  init(url: URL) throws {
    self.url = url
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    self.data = data
    let parsed = try Self.parseCentralDirectory(data)
    guard !parsed.isEmpty else { throw ZipError.corrupt("未找到图片条目") }
    self.entries = parsed.sorted { naturalCompare($0.name, $1.name) }
  }

  /// 无盘模式：直接从内存数据读（不落盘）
  init(data: Data) throws {
    self.url = URL(fileURLWithPath: "/dev/null")
    self.data = data
    let parsed = try Self.parseCentralDirectory(data)
    guard !parsed.isEmpty else { throw ZipError.corrupt("未找到图片条目") }
    self.entries = parsed.sorted { naturalCompare($0.name, $1.name) }
  }

  private static func parseCentralDirectory(_ data: Data) throws -> [Entry] {
    let (centralOffset, centralSize, entryCount) = try locateCentralDirectory(data)

    func readUInt16(_ offset: Int) -> UInt16 {
      guard offset + 2 <= data.count else { return 0 }
      return UInt16(data[data.startIndex + offset])
        | (UInt16(data[data.startIndex + offset + 1]) << 8)
    }
    func readUInt32(_ offset: Int) -> UInt32 {
      guard offset + 4 <= data.count else { return 0 }
      return UInt32(data[data.startIndex + offset])
        | (UInt32(data[data.startIndex + offset + 1]) << 8)
        | (UInt32(data[data.startIndex + offset + 2]) << 16)
        | (UInt32(data[data.startIndex + offset + 3]) << 24)
    }

    var parsed: [Entry] = []
    var cursor = Int(centralOffset)
    let end = min(Int(centralOffset + centralSize), data.count)
    while cursor + 46 <= end, parsed.count < Int(entryCount) {
      guard readUInt32(cursor) == 0x02014B50 else { break } // PK\x01\x02
      let method = readUInt16(cursor + 10)
      let compSize = readUInt32(cursor + 20)
      let uncompSize = readUInt32(cursor + 24)
      let nameLen = Int(readUInt16(cursor + 28))
      let extraLen = Int(readUInt16(cursor + 30))
      let commentLen = Int(readUInt16(cursor + 32))
      let lhoRaw = readUInt32(cursor + 42)
      guard cursor + 46 + nameLen + extraLen + commentLen <= end else { break }
      let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
      let name = String(data: nameData, encoding: .utf8)
        ?? String(data: nameData, encoding: .isoLatin1)
        ?? ""

      var zip64Comp: UInt64? = nil
      var zip64Uncomp: UInt64? = nil
      var zip64LHO: UInt64? = nil
      if extraLen > 0 {
        parseZip64Extra(
          data: data,
          range: (cursor + 46 + nameLen)..<(cursor + 46 + nameLen + extraLen),
          compSize: compSize,
          uncompSize: uncompSize,
          lho: lhoRaw,
          comp: &zip64Comp,
          uncomp: &zip64Uncomp,
          lhoOut: &zip64LHO
        )
      }

      let entry = Entry(
        name: name,
        compressedSize: zip64Comp ?? UInt64(compSize),
        uncompressedSize: zip64Uncomp ?? UInt64(uncompSize),
        method: method,
        localHeaderOffset: zip64LHO ?? UInt64(lhoRaw)
      )
      if isPageEntry(entry.name) {
        parsed.append(entry)
      }
      cursor += 46 + nameLen + extraLen + commentLen
    }
    return parsed
  }

  /// 解出一条图片数据
  func entryData(_ entry: Entry) throws -> Data {
    let lho = Int(entry.localHeaderOffset)
    guard lho + 30 <= data.count, readUInt32(lho) == 0x04034B50 else {
      throw ZipError.corrupt("本地头定位失败")
    }
    let nameLen = Int(readUInt16(lho + 26))
    let extraLen = Int(readUInt16(lho + 28))
    let dataStart = lho + 30 + nameLen + extraLen
    let dataEnd = dataStart + Int(entry.compressedSize)
    guard dataStart >= 0, dataEnd <= data.count else { throw ZipError.corrupt("数据范围越界") }
    let payload = data.subdata(in: dataStart..<dataEnd)

    switch entry.method {
    case 0:
      return payload
    case 8:
      let dstCapacity = Int(entry.uncompressedSize)
      guard dstCapacity > 0, dstCapacity < 400 * 1024 * 1024 else { throw ZipError.outOfMemory }
      var dst = Data(count: dstCapacity)
      let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
        payload.withUnsafeBytes { srcPtr -> Int in
          compression_decode_buffer(
            dstPtr.bindMemory(to: UInt8.self).baseAddress!, dstCapacity,
            srcPtr.bindMemory(to: UInt8.self).baseAddress!, payload.count,
            nil, COMPRESSION_ZLIB
          )
        }
      }
      guard written == dstCapacity else { throw ZipError.corrupt("解压不完整") }
      return dst
    default:
      throw ZipError.unsupportedMethod(entry.method)
    }
  }

  func entryData(at index: Int) -> Data? {
    guard entries.indices.contains(index) else { return nil }
    return try? entryData(entries[index])
  }

  // MARK: - 私有

  private func readUInt16(_ offset: Int) -> UInt16 {
    guard offset + 2 <= data.count else { return 0 }
    return UInt16(data[data.startIndex + offset])
      | (UInt16(data[data.startIndex + offset + 1]) << 8)
  }

  private func readUInt32(_ offset: Int) -> UInt32 {
    guard offset + 4 <= data.count else { return 0 }
    return UInt32(data[data.startIndex + offset])
      | (UInt32(data[data.startIndex + offset + 1]) << 8)
      | (UInt32(data[data.startIndex + offset + 2]) << 16)
      | (UInt32(data[data.startIndex + offset + 3]) << 24)
  }

  private func readUInt64(_ offset: Int) -> UInt64 {
    var result: UInt64 = 0
    for i in 0..<8 {
      guard offset + i < data.count else { return 0 }
      result |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
    }
    return result
  }

  private static func isPageEntry(_ name: String) -> Bool {
    guard !name.hasSuffix("/") else { return false }
    guard !name.contains("__MACOSX/") else { return false }
    let base = (name as NSString).lastPathComponent
    guard !base.isEmpty, !base.hasPrefix(".") else { return false }
    return MediaSniff.isImage(base)
  }

  /// 找 EOCD（含 zip64）
  /// 供远程直读复用：定位中央目录（data 为文件尾部窗口）
  nonisolated static func locateCentralDirectoryPublic(_ data: Data) throws -> (UInt64, UInt64, UInt64) {
    try locateCentralDirectory(data)
  }

  /// 供远程直读复用：解析中央目录段（data 从目录起点开始），只返回条目
  nonisolated static func parseCentralDirectorySlice(_ data: Data) -> [Entry]? {
    func readU16(_ o: Int) -> UInt16 {
      guard o + 2 <= data.count else { return 0 }
      return UInt16(data[data.startIndex + o]) | (UInt16(data[data.startIndex + o + 1]) << 8)
    }
    func readU32(_ o: Int) -> UInt32 {
      guard o + 4 <= data.count else { return 0 }
      return UInt32(data[data.startIndex + o])
        | (UInt32(data[data.startIndex + o + 1]) << 8)
        | (UInt32(data[data.startIndex + o + 2]) << 16)
        | (UInt32(data[data.startIndex + o + 3]) << 24)
    }
    var parsed: [Entry] = []
    var cursor = 0
    while cursor + 46 <= data.count {
      guard readU32(cursor) == 0x02014B50 else { break }
      let method = readU16(cursor + 10)
      let compSize = readU32(cursor + 20)
      let uncompSize = readU32(cursor + 24)
      let nameLen = Int(readU16(cursor + 28))
      let extraLen = Int(readU16(cursor + 30))
      let commentLen = Int(readU16(cursor + 32))
      let lhoRaw = readU32(cursor + 42)
      guard cursor + 46 + nameLen + extraLen + commentLen <= data.count else { break }
      let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameLen))
      let name = String(data: nameData, encoding: .utf8)
        ?? String(data: nameData, encoding: .isoLatin1)
        ?? ""
      parsed.append(Entry(
        name: name,
        compressedSize: UInt64(compSize),
        uncompressedSize: UInt64(uncompSize),
        method: method,
        localHeaderOffset: UInt64(lhoRaw)
      ))
      cursor += 46 + nameLen + extraLen + commentLen
    }
    return parsed.isEmpty ? nil : parsed
  }

  nonisolated static func isPageEntryName(_ name: String) -> Bool {
    isPageEntry(name)
  }

  private static func locateCentralDirectory(_ data: Data) throws -> (UInt64, UInt64, UInt64) {
    let maxScan = min(data.count, 65_536 + 22)
    guard data.count > 22, maxScan > 22 else { throw ZipError.notZip }
    let scanStart = data.count - maxScan

    var eocdOffset = -1
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
      var i = data.count - 22
      while i >= scanStart {
        if ptr.loadUnaligned(fromByteOffset: i, as: UInt32.self) == 0x06054B50 {
          eocdOffset = i
          break
        }
        i -= 1
      }
    }
    guard eocdOffset >= 0 else { throw ZipError.notZip }

    let get16: (Int) -> UInt16 = { off in
      UInt16(ptrValue(data, off)) | (UInt16(ptrValue(data, off + 1)) << 8)
    }
    let get32: (Int) -> UInt32 = {
      UInt32(ptrValue(data, $0))
        | (UInt32(ptrValue(data, $0 + 1)) << 8)
        | (UInt32(ptrValue(data, $0 + 2)) << 16)
        | (UInt32(ptrValue(data, $0 + 3)) << 24)
    }
    _ = get16

    var entryCount = UInt64(get32(eocdOffset + 10))
    var centralSize = UInt64(get32(eocdOffset + 12))
    var centralOffset = UInt64(get32(eocdOffset + 16))

    // 0xFFFFFFFF 溢出标记 → 读 zip64
    if entryCount == 0xFFFF_FFFF || centralOffset == 0xFFFF_FFFF || centralSize == 0xFFFF_FFFF {
      let locatorOffset = eocdOffset - 20
      if locatorOffset >= 0, get32(locatorOffset) == 0x07064B50 {
        let eocd64Offset = Int(get64(data, locatorOffset + 8))
        if eocd64Offset >= 0, eocd64Offset + 56 <= data.count,
           get32(eocd64Offset) == 0x06064B50 {
          entryCount = get64(data, eocd64Offset + 32)
          centralSize = get64(data, eocd64Offset + 40)
          centralOffset = get64(data, eocd64Offset + 48)
        }
      }
    }
    guard centralOffset + centralSize <= UInt64(data.count) else {
      throw ZipError.corrupt("中央目录范围异常")
    }
    return (centralOffset, centralSize, entryCount)
  }

  private static func ptrValue(_ data: Data, _ offset: Int) -> UInt8 {
    data[data.startIndex + offset]
  }

  private static func get64(_ data: Data, _ offset: Int) -> UInt64 {
    var result: UInt64 = 0
    for i in 0..<8 {
      guard offset + i < data.count else { return 0 }
      result |= UInt64(data[data.startIndex + offset + i]) << (8 * i)
    }
    return result
  }

  /// 解析 zip64 扩展字段（0x0001），只在对应字段为溢出标记时替换
  private static func parseZip64Extra(
    data: Data,
    range: Range<Int>,
    compSize: UInt32,
    uncompSize: UInt32,
    lho: UInt32,
    comp: inout UInt64?,
    uncomp: inout UInt64?,
    lhoOut: inout UInt64?
  ) {
    var cursor = range.lowerBound
    while cursor + 4 <= range.upperBound {
      let tag = UInt16(data[data.startIndex + cursor]) | (UInt16(data[data.startIndex + cursor + 1]) << 8)
      let size = Int(UInt16(data[data.startIndex + cursor + 2]) | (UInt16(data[data.startIndex + cursor + 3]) << 8))
      let bodyStart = cursor + 4
      guard bodyStart + size <= range.upperBound else { break }
      if tag == 0x0001 {
        var fieldOffset = bodyStart
        let needUncomp = uncompSize == 0xFFFF_FFFF
        let needComp = compSize == 0xFFFF_FFFF
        let needLHO = lho == 0xFFFF_FFFF
        if needUncomp, fieldOffset + 8 <= bodyStart + size {
          uncomp = get64(data, fieldOffset); fieldOffset += 8
        }
        if needComp, fieldOffset + 8 <= bodyStart + size {
          comp = get64(data, fieldOffset); fieldOffset += 8
        }
        if needLHO, fieldOffset + 8 <= bodyStart + size {
          lhoOut = get64(data, fieldOffset)
        }
      }
      cursor = bodyStart + size
    }
  }
}
