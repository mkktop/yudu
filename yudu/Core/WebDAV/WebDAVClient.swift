import Foundation
import UIKit

// MARK: - WebDAV 客户端（PROPFIND / GET / HEAD，Basic 认证）

nonisolated struct WebDAVItem: Sendable {
  var url: URL
  var name: String
  var isDirectory: Bool
  var contentLength: Int64
  var lastModified: Date?

  var isImage: Bool { !isDirectory && MediaSniff.isImage(name) }
  var isArchive: Bool { !isDirectory && MediaSniff.isArchive(name) }
  var isPDF: Bool { !isDirectory && MediaSniff.isPDF(name) }
}

nonisolated final class WebDAVClient: @unchecked Sendable {

  enum WebDAVError: Error, LocalizedError {
    case badStatus(Int)
    case unreachable(String)

    var errorDescription: String? {
      switch self {
      case .badStatus(let code):
        "服务器返回 \(code)" + (code == 401 ? "（账号或密码不对）" : code == 403 ? "（没有权限）" : "")
      case .unreachable(let why):
        "连不上服务器：\(why)"
      }
    }
  }

  let baseURL: URL
  private let authHeader: String?

  init(baseURL: URL, username: String?, password: String?) {
    self.baseURL = baseURL
    if let username, let password,
       let raw = "\(username):\(password)".data(using: .utf8) {
      self.authHeader = "Basic " + raw.base64EncodedString()
    } else {
      self.authHeader = nil
    }
  }

  private func makeRequest(_ url: URL, method: String, depth: String? = nil, body: Data? = nil) -> URLRequest {
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = 30
    if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
    if let depth { req.setValue(depth, forHTTPHeaderField: "Depth") }
    if let body {
      req.httpBody = body
      req.setValue("application/xml", forHTTPHeaderField: "Content-Type")
    }
    return req
  }

  private static let propfindBody = """
  <?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
  """.data(using: .utf8)!

  /// 列目录（Depth 1，含直接子项；不含请求目录自身）
  func list(_ url: URL) async throws -> [WebDAVItem] {
    let req = makeRequest(url, method: "PROPFIND", depth: "1", body: Self.propfindBody)
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw WebDAVError.badStatus(-1) }
    guard http.statusCode == 207 else { throw WebDAVError.badStatus(http.statusCode) }
    return MultistatusParser(base: baseURL, requestURL: url).parse(data)
  }

  /// 验证连接（Depth 0，只要能返回 207 就算通）
  func verify() async throws {
    let req = makeRequest(baseURL, method: "PROPFIND", depth: "0", body: Self.propfindBody)
    let (_, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw WebDAVError.badStatus(-1) }
    guard http.statusCode == 207 else { throw WebDAVError.badStatus(http.statusCode) }
  }

  /// 文件大小（挂载前的体积检查用）
  func contentLength(_ url: URL) async -> Int64? {
    var req = makeRequest(url, method: "HEAD")
    req.timeoutInterval = 10
    guard let (_, response) = try? await URLSession.shared.data(for: req),
          let http = response as? HTTPURLResponse,
          http.statusCode == 200
    else { return nil }
    return http.expectedContentLength
  }

  /// 下载到指定路径（临时文件落位，覆盖旧文件）
  func download(_ url: URL, to dest: URL) async throws {
    let req = makeRequest(url, method: "GET")
    let (tmpURL, response) = try await URLSession.shared.download(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw WebDAVError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
    }
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: tmpURL, to: dest)
  }

  /// 拉一段数据（单张图片）
  func get(_ url: URL) async throws -> Data {
    let req = makeRequest(url, method: "GET")
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw WebDAVError.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
    }
    return data
  }

  /// 同步取数据（页源在后台解码线程里用）
  func getSync(_ url: URL) -> Data? {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Data?
    Task.detached {
      result = try? await self.get(url)
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }
}

// MARK: - multistatus XML 解析

nonisolated final class MultistatusParser: NSObject, XMLParserDelegate {
  private let base: URL
  private let requestPath: String
  private var items: [WebDAVItem] = []
  private var text = ""
  private var href: String?
  private var name: String?
  private var length: Int64 = 0
  private var isDir = false
  private var modified: Date?

  private static let modifiedFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f
  }()

  init(base: URL, requestURL: URL) {
    self.base = base
    self.requestPath = Self.normalizedPath(requestURL.path)
  }

  func parse(_ data: Data) -> [WebDAVItem] {
    let parser = XMLParser(data: data)
    parser.delegate = self
    parser.parse()
    return items
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    // XMLParser 默认返回带命名空间前缀的限定名（d:response），剥掉前缀再匹配
    let element = elementName.components(separatedBy: ":").last ?? elementName
    text = ""
    if element == "response" {
      href = nil; name = nil; length = 0; isDir = false; modified = nil
    } else if element == "collection" {
      isDir = true
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    text += string
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    switch elementName.components(separatedBy: ":").last ?? elementName {
    case "href":
      href = value
    case "displayname":
      name = value
    case "getcontentlength":
      length = Int64(value) ?? 0
    case "getlastmodified":
      modified = Self.modifiedFormatter.date(from: value)
    case "response":
      if let href,
         let url = Self.resolve(href: href, base: base),
         Self.normalizedPath(url.path) != requestPath {
        items.append(
          WebDAVItem(
            url: url,
            name: name?.isEmpty == false ? name! : url.lastPathComponent,
            isDirectory: isDir,
            contentLength: length,
            lastModified: modified
          )
        )
      }
    default:
      break
    }
    text = ""
  }

  /// href 可能是绝对地址也可能是路径；标准服务器返回的是已编码 href，直接解析；
  /// 裸 UTF-8 的 href URL(string:) 会失败，那时才补编码（避免双重编码）
  private static func resolve(href: String, base: URL) -> URL? {
    if let absolute = URL(string: href), absolute.scheme != nil {
      return absolute
    }
    if let url = URL(string: href, relativeTo: base) {
      return url.absoluteURL
    }
    let encoded = href.addingPercentEncoding(
      withAllowedCharacters: CharacterSet.urlPathAllowed.union(CharacterSet(charactersIn: "?&="))
    ) ?? href
    return URL(string: encoded, relativeTo: base)?.absoluteURL
  }

  /// 路径规范化（空 → "/"，剥尾部斜杠），用于把"请求目录自身"从结果里剔除
  private static func normalizedPath(_ raw: String) -> String {
    var path = raw
    if path.isEmpty { path = "/" }
    while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
