import Foundation
import CryptoKit
import Security
import UIKit

// MARK: - 天翼云盘客户端（协议移植自桌面版 cloud189-sdk）

nonisolated struct Cloud189Item: Sendable {
  var id: String
  var name: String
  var isDirectory: Bool
  var size: Int64
  var lastModified: Date?

  var isImage: Bool { !isDirectory && MediaSniff.isImage(name) }
  var isArchive: Bool { !isDirectory && MediaSniff.isArchive(name) }
  var isPDF: Bool { !isDirectory && MediaSniff.isPDF(name) }
}

nonisolated final class Cloud189Client: @unchecked Sendable {

  enum Cloud189Error: Error, LocalizedError {
    case authExpired
    case ratesExceeded
    case badStatus(Int, String)
    case loginFailed(String)
    case qrExpired

    var errorDescription: String? {
      switch self {
      case .authExpired: "登录已失效，请重新扫码"
      case .ratesExceeded: "操作太频繁，稍等一会儿再试"
      case .badStatus(let code, let why): "天翼云盘返回 \(code)：\(why)"
      case .loginFailed(let why): "登录失败：\(why)"
      case .qrExpired: "二维码已过期，请刷新后重新扫"
      }
    }
  }

  // 会话（Keychain 持久化，账号维度单会话）
  struct Session: Codable {
    var sessionKey: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var loginName: String?
  }

  static let sessionAccount = "cloud189-session"
  private(set) var session: Session?
  /// 个人云（nil）或某个家庭云的 familyId
  var familyId: String?

  init() {
    if let data = Keychain.get(account: Self.sessionAccount),
       let decoded = try? JSONDecoder().decode(Session.self, from: Data(data.utf8)) {
      session = decoded
    }
  }

  var isLoggedIn: Bool { session != nil }

  func saveSession() {
    if let session, let data = try? JSONEncoder().encode(session) {
      Keychain.set(String(data: data, encoding: .utf8) ?? "", account: Self.sessionAccount)
    }
  }

  func logout() {
    session = nil
    Keychain.remove(account: Self.sessionAccount)
  }

  // MARK: - 常量

  private static let appId = "8025431004"
  private static let returnUrl = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html"
  private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36"
  private static let apiBase = URL(string: "https://api.cloud.189.cn")!
  private static let authBase = URL(string: "https://open.e.189.cn")!
  private static let webBase = URL(string: "https://cloud.189.cn")!

  // MARK: - 请求节流（300ms 串行，防风控）

  private static let throttle = MinInterval(milliseconds: 300)

  // MARK: - 扫码登录

  struct QRLogin {
    var uuid: String
    var lt: String
    var paramId: String
    var reqId: String
  }

  /// 第一步：取登录页参数 + 申请二维码 uuid
  func beginQRLogin() async throws -> QRLogin {
    let page = try await fetchLoginPageParams()
    var req = URLRequest(url: Self.authBase.appendingPathComponent("api/logbox/oauth2/getUUID.do"))
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://open.e.189.cn", forHTTPHeaderField: "Referer")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data("appId=\(Self.appId)".utf8)
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let uuid = json["uuid"] as? String
    else { throw Cloud189Error.loginFailed("获取二维码失败") }
    return QRLogin(uuid: uuid, lt: page.lt, paramId: page.paramId, reqId: page.reqId)
  }

  private func fetchLoginPageParams() async throws -> (lt: String, paramId: String, reqId: String) {
    var components = URLComponents(url: Self.webBase.appendingPathComponent("api/portal/unifyLoginForPC.action"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "appId", value: Self.appId),
      URLQueryItem(name: "clientType", value: "10020"),
      URLQueryItem(name: "returnURL", value: Self.returnUrl),
      URLQueryItem(name: "timeStamp", value: String(Int(Date().timeIntervalSince1970 * 1000))),
    ]
    var req = URLRequest(url: components.url!)
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, _) = try await URLSession.shared.data(for: req)
    let html = String(data: data, encoding: .utf8) ?? ""
    func match(_ pattern: String) -> String? {
      guard let regex = try? NSRegularExpression(pattern: pattern),
            let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) else { return nil }
      return String(html[r])
    }
    let captcha = match(#"captchaToken' value='([^']+)'"#)
    let lt = match(#"lt = "([^"]+)""#)
    let paramId = match(#"paramId = "([^"]+)""#)
    let reqId = match(#"reqId = "([^"]+)""#)
    guard let lt, let paramId, let reqId else {
      throw Cloud189Error.loginFailed("登录页解析失败")
    }
    _ = captcha
    return (lt, paramId, reqId)
  }

  /// 轮询扫码状态；返回 true 表示登录完成
  func pollQRLogin(_ login: QRLogin) async throws -> Bool {
    await Self.throttle.wait()
    var req = URLRequest(url: Self.authBase.appendingPathComponent("api/logbox/oauth2/qrcodeLoginState.do"))
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://open.e.189.cn", forHTTPHeaderField: "Referer")
    req.setValue(login.reqId, forHTTPHeaderField: "Reqid")
    req.setValue(login.lt, forHTTPHeaderField: "lt")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-ddHH:mm:ss.SSS"
    let body: [String: String] = [
      "appId": Self.appId,
      "clientType": "10020",
      "returnUrl": Self.returnUrl,
      "paramId": login.paramId,
      "uuid": login.uuid,
      "date": formatter.string(from: .now),
      "timeStamp": String(Int(Date().timeIntervalSince1970 * 1000)),
    ]
    req.httpBody = Self.formEncode(body)

    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Cloud189Error.loginFailed("轮询响应异常")
    }
    let status = (json["status"] as? NSNumber)?.intValue ?? (json["status"] as? String).flatMap(Int.init) ?? -999
    switch status {
    case 0:
      guard let redirect = json["redirectUrl"] as? String else {
        throw Cloud189Error.loginFailed("登录响应缺少跳转地址")
      }
      try await exchangeSession(redirectURL: redirect)
      return true
    case -106, -11002:
      return false // 等待扫码 / 待确认
    case -11001:
      throw Cloud189Error.qrExpired
    default:
      return false
    }
  }

  /// 扫码/密码登录收尾：换正式会话
  private func exchangeSession(redirectURL: String) async throws {
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "appId", value: Self.appId),
      URLQueryItem(name: "clientType", value: "TELEPC"),
      URLQueryItem(name: "version", value: "6.2"),
      URLQueryItem(name: "channelId", value: "web_cloud.189.cn"),
      URLQueryItem(name: "rand", value: String(Int(Date().timeIntervalSince1970 * 1000))),
      URLQueryItem(name: "redirectURL", value: redirectURL),
    ]
    var req = URLRequest(url: URL(string: Self.apiBase.absoluteString + "/getSessionForPC.action?" + (components.percentEncodedQuery ?? ""))!)
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sessionKey = json["sessionKey"] as? String,
          let accessToken = json["accessToken"] as? String
    else {
      throw Cloud189Error.loginFailed("会话获取失败")
    }
    session = Session(
      sessionKey: sessionKey,
      accessToken: accessToken,
      refreshToken: json["refreshToken"] as? String,
      expiresAt: Date.now.addingTimeInterval(6 * 24 * 3600),
      loginName: json["loginName"] as? String
    )
    saveSession()
  }

  // MARK: - 会话恢复与刷新

  /// 确保会话可用（accessToken 过期时用 refreshToken 刷新）
  func ensureSession() async throws {
    guard var current = session else { throw Cloud189Error.authExpired }
    if current.expiresAt > .now { return }
    guard let refresh = current.refreshToken else { throw Cloud189Error.authExpired }
    var req = URLRequest(url: Self.authBase.appendingPathComponent("api/oauth2/refreshToken.do"))
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Self.formEncode([
      "clientId": Self.appId,
      "refreshToken": refresh,
      "grantType": "refresh_token",
      "format": "json",
    ])
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = json["accessToken"] as? String
    else {
      session = nil
      saveSession()
      throw Cloud189Error.authExpired
    }
    current.accessToken = token
    current.refreshToken = json["refreshToken"] as? String ?? current.refreshToken
    if let seconds = json["expiresIn"] as? Double {
      current.expiresAt = .now.addingTimeInterval(seconds)
    }
    session = current
    saveSession()
  }

  // MARK: - Open API（AccessToken 签名）

  private func apiGet(_ path: String, params: [String: String], retried: Bool = false) async throws -> [String: Any] {
    try await ensureSession()
    await Self.throttle.wait()
    guard let session else { throw Cloud189Error.authExpired }

    let ts = String(Int(Date().timeIntervalSince1970 * 1000))
    var all = params
    all["Timestamp"] = ts
    all["AccessToken"] = session.accessToken
    let signature = Self.md5Signature(all)

    var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }

    var req = URLRequest(url: components.url!)
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("1", forHTTPHeaderField: "Sign-Type")
    req.setValue(session.accessToken, forHTTPHeaderField: "Accesstoken")
    req.setValue(ts, forHTTPHeaderField: "Timestamp")
    req.setValue(signature, forHTTPHeaderField: "Signature")

    let (data, response) = try await URLSession.shared.data(for: req)
    let http = response as? HTTPURLResponse
    let body = String(data: data, encoding: .utf8) ?? ""

    // 会话失效：刷新一次后重试
    if http?.statusCode == 400, body.contains("InvalidAccessToken"), !retried {
      try await ensureSession(force: true)
      return try await apiGet(path, params: params, retried: true)
    }
    if body.contains("RatesExceed") || http?.statusCode == 429 {
      throw Cloud189Error.ratesExceeded
    }
    guard (http?.statusCode ?? 500) == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw Cloud189Error.badStatus(http?.statusCode ?? -1, String(body.prefix(120)))
    }
    if let errorCode = json["errorCode"] as? String, errorCode.contains("InvalidSession") {
      throw Cloud189Error.authExpired
    }
    return json
  }

  private func ensureSession(force: Bool) async throws {
    if force, let refresh = session?.refreshToken {
      session?.expiresAt = .distantPast
      _ = refresh
    }
    try await ensureSession()
  }

  /// MD5 签名：全部参数按 "k=v" 字符串字典序排序 & 连接后取 MD5 hex
  static func md5Signature(_ params: [String: String]) -> String {
    let joined = params.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
    let digest = Insecure.MD5.hash(data: Data(joined.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  static func formEncode(_ fields: [String: String]) -> Data {
    let pairs = fields.map { key, value in
      "\(key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
    }
    return Data(pairs.joined(separator: "&").utf8)
  }

  // MARK: - 家庭云

  /// 家庭列表（userRole=1 为主家庭）
  func familyList() async throws -> [(familyId: String, name: String)] {
    let json = try await apiGet("open/family/manage/getFamilyList.action", params: [:])
    guard let list = json["familyInfoResp"] as? [[String: Any]] else { return [] }
    return list.compactMap { info in
      guard let id = info["familyId"] as? String ?? (info["familyId"] as? NSNumber)?.stringValue else { return nil }
      let name = info["remarkName"] as? String ?? "家庭云"
      return (id, name)
    }
  }

  // MARK: - 列目录（含分页与家庭云根目录下钻）

  func listFiles(folderId: String, familyId: String? = nil) async throws -> [Cloud189Item] {
    var effectiveFolder = folderId
    // 家庭云 -11 根目录只返回系统空文件夹，下钻到 我的应用(-16)/家庭云 对齐官方视图
    if let familyId, folderId == "-11" {
      let probe = try await listFilesOnce(folderId: "-16", familyId: familyId, pageNum: 1)
      if let familyDir = probe.items.first(where: { $0.isDirectory && $0.name == "家庭云" }) {
        effectiveFolder = familyDir.id
      }
    }

    var result: [Cloud189Item] = []
    var pageNum = 1
    while true {
      let page = try await listFilesOnce(folderId: effectiveFolder, familyId: familyId, pageNum: pageNum)
      result.append(contentsOf: page.items)
      if result.count >= page.count || page.items.isEmpty { break }
      pageNum += 1
    }
    return result
  }

  private func listFilesOnce(folderId: String, familyId: String?, pageNum: Int) async throws -> (items: [Cloud189Item], count: Int) {
    var params: [String: String] = [
      "folderId": folderId,
      "pageNum": String(pageNum),
      "pageSize": "200",
      "mediaType": "0",
      "orderBy": "1",
      "descending": "false",
      "iconOption": "1",
    ]
    let path: String
    if let familyId {
      params["familyId"] = familyId
      path = "open/family/file/listFiles.action"
    } else {
      path = "open/file/listFiles.action"
    }
    let json = try await apiGet(path, params: params)
    guard let fileListAO = json["fileListAO"] as? [String: Any] else { return ([], 0) }
    let count = (fileListAO["count"] as? NSNumber)?.intValue ?? 0

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)

    var items: [Cloud189Item] = []
    for folder in (fileListAO["folderList"] as? [[String: Any]]) ?? [] {
      guard let id = (folder["id"] as? NSNumber)?.stringValue ?? folder["id"] as? String,
            let name = folder["name"] as? String else { continue }
      items.append(Cloud189Item(
        id: id, name: name, isDirectory: true, size: 0,
        lastModified: formatter.date(from: folder["lastOpTime"] as? String ?? "")
      ))
    }
    for file in (fileListAO["fileList"] as? [[String: Any]]) ?? [] {
      guard let id = (file["id"] as? NSNumber)?.stringValue ?? file["id"] as? String,
            let name = file["name"] as? String else { continue }
      items.append(Cloud189Item(
        id: id, name: name, isDirectory: false,
        size: (file["size"] as? NSNumber)?.int64Value ?? 0,
        lastModified: formatter.date(from: file["lastOpTime"] as? String ?? "")
      ))
    }
    return (items, count)
  }

  // MARK: - 下载直链

  /// 取下载直链（XML 实体已解码）；直链有时效，用前即取
  func downloadURL(fileId: String, familyId: String?) async throws -> URL {
    var params = ["fileId": fileId]
    let path: String
    if let familyId {
      params["familyId"] = familyId
      path = "open/family/file/getFileDownloadUrl.action"
    } else {
      path = "open/file/getFileDownloadUrl.action"
    }
    let json = try await apiGet(path, params: params)
    guard let raw = json["fileDownloadUrl"] as? String else {
      throw Cloud189Error.badStatus(0, "未取得下载地址")
    }
    // 直链里 & 是 &amp;，不解码请求必 403
    let decoded = raw
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
    guard let url = URL(string: decoded) else {
      throw Cloud189Error.badStatus(0, "下载地址无效")
    }
    return url
  }

  /// 下载文件到本地（直链过期自动换新重试一次）
  func download(fileId: String, familyId: String?, to dest: URL) async throws {
    var lastError: Error?
    for _ in 0..<2 {
      let url = try await downloadURL(fileId: fileId, familyId: familyId)
      var req = URLRequest(url: url)
      req.timeoutInterval = 60
      do {
        let (tmp, response) = try await URLSession.shared.download(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
          throw Cloud189Error.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "下载失败")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return
      } catch {
        lastError = error
      }
    }
    throw lastError ?? Cloud189Error.badStatus(0, "下载失败")
  }

  /// 拉一小段数据（散图单张）
  func fetchData(fileId: String, familyId: String?) async throws -> Data {
    let url = try await downloadURL(fileId: fileId, familyId: familyId)
    var req = URLRequest(url: url)
    req.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw Cloud189Error.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "取图失败")
    }
    return data
  }
}

// MARK: - 最小间隔串行闸（300ms，防风控）

actor MinInterval {
  private let interval: TimeInterval
  private var lastFire = Date.distantPast

  init(milliseconds: Int) {
    interval = Double(milliseconds) / 1000
  }

  func wait() async {
    let now = Date.now
    let earliest = lastFire.addingTimeInterval(interval)
    if now < earliest {
      try? await Task.sleep(for: .seconds(earliest.timeIntervalSince(now)))
      lastFire = Date.now
    } else {
      lastFire = now
    }
  }
}
