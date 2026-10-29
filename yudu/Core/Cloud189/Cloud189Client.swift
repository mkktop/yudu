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

    var errorDescription: String? {
      switch self {
      case .authExpired: "登录已失效，请重新扫码"
      case .ratesExceeded: "操作太频繁，稍等一会儿再试"
      case .badStatus(let code, let why): "天翼云盘返回 \(code)：\(why)"
      case .loginFailed(let why): "登录失败：\(why)"
      }
    }
  }

  // 会话（Keychain 持久化，账号维度单会话）
  struct Session: Codable, Sendable {
    var sessionKey: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var loginName: String?
  }

  static let sessionAccount = "cloud189-session"
  private let sessionLock = NSLock()
  private var storedSession: Session?
  private var refreshTask: Task<Session, Error>?
  // 家庭云 id 由调用方按请求传入，客户端本身不持有可变状态。

  init() {
    if let data = Keychain.get(account: Self.sessionAccount),
       let decoded = try? JSONDecoder().decode(Session.self, from: Data(data.utf8)) {
      storedSession = decoded
    }
  }

  var session: Session? { sessionLock.withLock { storedSession } }
  var isLoggedIn: Bool { session != nil }

  private func setSession(_ value: Session?) {
    sessionLock.withLock { storedSession = value }
  }

  func saveSession() {
    if let session, let data = try? JSONEncoder().encode(session) {
      Keychain.set(String(data: data, encoding: .utf8) ?? "", account: Self.sessionAccount)
    } else {
      // 会话已失效：必须同时清掉钥匙串，否则下次启动会读到过期会话，
      // 登录页会误以为已登录而无法回到扫码流程。
      Keychain.remove(account: Self.sessionAccount)
    }
  }

  func logout() {
    setSession(nil)
    sessionLock.withLock { refreshTask?.cancel(); refreshTask = nil }
    saveSession()
  }

  // MARK: - 常量

  private static let appId = "8025431004"
  private static let accountType = "02"
  /// cloud.189.cn /open 系接口的应用 key（SDK signatureAppKey 常量）
  private static let webAppKey = "600100422"
  private static let returnUrl = "https://m.cloud.189.cn/zhuanti/2020/loginErrorPc/index.html"
  private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/87.0.4280.88 Safari/537.36"
  private static let apiBase = URL(string: "https://api.cloud.189.cn")!
  private static let authBase = URL(string: "https://open.e.189.cn")!
  private static let webBase = URL(string: "https://cloud.189.cn")!

  // MARK: - 请求节流（300ms 串行，防风控）

  private static let throttle = MinInterval(milliseconds: 300)

  // MARK: - 直链短缓存
  //
  // 同一页往往先取图头（尺寸）再取整图，两次都解析直链就要吃两次 300ms 节流。
  // 直链本身有时效，这里只缓存 90 秒；403/410 时失效重试。

  private let urlCacheLock = NSLock()
  private var downloadURLCache: [String: (url: URL, at: Date)] = [:]
  private static let downloadURLTTL: TimeInterval = 90

  private func urlCacheKey(_ fileId: String, _ familyId: String?) -> String {
    "\(familyId ?? "p"):\(fileId)"
  }

  private func cachedDownloadURL(_ fileId: String, _ familyId: String?) -> URL? {
    let key = urlCacheKey(fileId, familyId)
    urlCacheLock.lock()
    defer { urlCacheLock.unlock() }
    guard let hit = downloadURLCache[key],
          Date().timeIntervalSince(hit.at) < Self.downloadURLTTL else {
      downloadURLCache.removeValue(forKey: key)
      return nil
    }
    return hit.url
  }

  private func storeDownloadURL(_ url: URL, fileId: String, familyId: String?) {
    urlCacheLock.lock()
    downloadURLCache[urlCacheKey(fileId, familyId)] = (url, Date())
    if downloadURLCache.count > 64 {
      let oldest = downloadURLCache.sorted { $0.value.at < $1.value.at }
      for (key, _) in oldest.prefix(downloadURLCache.count / 2) {
        downloadURLCache.removeValue(forKey: key)
      }
    }
    urlCacheLock.unlock()
  }

  private func invalidateDownloadURL(fileId: String, familyId: String?) {
    urlCacheLock.lock()
    downloadURLCache.removeValue(forKey: urlCacheKey(fileId, familyId))
    urlCacheLock.unlock()
  }

  // MARK: - 扫码登录

  struct QRLogin {
    var uuid: String
    var encryuuid: String
    var lt: String
    var paramId: String
    var reqId: String
  }

  /// 轮询扫码状态
  enum QRScanState { case waiting, scanned, confirmed, expired }

  /// 第一步：取登录页参数 + 申请二维码 uuid（uuid 即二维码内容，encryuuid 轮询时配对校验）
  func beginQRLogin() async throws -> QRLogin {
    let page = try await fetchLoginPageParams()
    var req = URLRequest(url: Self.authBase.appendingPathComponent("api/logbox/oauth2/getUUID.do"))
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://open.e.189.cn", forHTTPHeaderField: "Referer")
    req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data("appId=\(Self.appId)".utf8)
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let uuid = json["uuid"] as? String,
          let encryuuid = json["encryuuid"] as? String
    else { throw Cloud189Error.loginFailed("获取二维码失败") }
    return QRLogin(uuid: uuid, encryuuid: encryuuid, lt: page.lt, paramId: page.paramId, reqId: page.reqId)
  }

  struct LoginFormParams {
    var captchaToken: String
    var lt: String
    var paramId: String
    var reqId: String
  }

  private func fetchLoginPageParams() async throws -> LoginFormParams {
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
    guard let captcha, let lt, let paramId, let reqId else {
      throw Cloud189Error.loginFailed("登录页解析失败")
    }
    return LoginFormParams(captchaToken: captcha, lt: lt, paramId: paramId, reqId: reqId)
  }

  /// 轮询扫码状态；confirmed 表示已确认并换到正式会话
  func pollQRLogin(_ login: QRLogin) async throws -> QRScanState {
    await Self.throttle.wait()
    var req = URLRequest(url: Self.authBase.appendingPathComponent("api/logbox/oauth2/qrcodeLoginState.do"))
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://open.e.189.cn", forHTTPHeaderField: "Referer")
    req.setValue(login.reqId, forHTTPHeaderField: "Reqid")
    req.setValue(login.lt, forHTTPHeaderField: "lt")
    req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
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
      "encryuuid": login.encryuuid,
      "date": formatter.string(from: .now),
      "timeStamp": String(Int(Date().timeIntervalSince1970 * 1000)),
    ]
    req.httpBody = Self.formEncode(body)

    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw Cloud189Error.loginFailed("轮询响应异常")
    }
    let status = (json["status"] as? NSNumber)?.intValue ?? (json["status"] as? String).flatMap(Int.init) ?? -999
    if status != -106 { Diag.log("poll status=\(status) redirect=\((json["redirectUrl"] as? String)?.isEmpty == false ? "有" : "无")") }
    switch status {
    case 0:
      guard let redirect = json["redirectUrl"] as? String else {
        throw Cloud189Error.loginFailed("登录响应缺少跳转地址")
      }
      try await exchangeSession(redirectURL: redirect)
      return .confirmed
    case -11001:
      return .expired
    case -11002:
      return .scanned
    default:
      return .waiting // -106 等待扫码，其余未知码按等待处理
    }
  }

  /// 调 getSessionForPC（redirectURL 换登录会话 / accessToken 换正式会话，共用请求），返回解析后的 JSON
  private func requestSessionRaw(_ extra: [String: String]) async throws -> ([String: Any], Data) {
    // 查询串手工构造：URLComponents 会把值里的 + 原样保留（服务器解码成空格），
    // Node/URLSearchParams 是 %2B——对齐桌面版行为，否则带 + 的令牌必然校验失败
    func qe(_ s: String) -> String {
      s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
    var query = [
      "appId": Self.appId,
      "clientType": "TELEPC",
      "version": "6.2",
      "channelId": "web_cloud.189.cn",
      "rand": String(Int(Date().timeIntervalSince1970 * 1000)),
    ]
    for (key, value) in extra { query[key] = value }
    let encoded = query
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\(qe($0.value))" }
      .joined(separator: "&")
    var req = URLRequest(url: URL(string: Self.apiBase.absoluteString + "/getSessionForPC.action?" + encoded)!)
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      Diag.log("getSessionForPC[\(extra.keys.sorted().joined(separator: ","))] 非JSON: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
      throw Cloud189Error.loginFailed("会话获取失败：\(String(data: data.prefix(120), encoding: .utf8) ?? "")")
    }
    return (json, data)
  }

  /// 扫码/密码登录收尾：redirectURL 换登录会话，再用 accessToken 换正式会话
  private func exchangeSession(redirectURL: String) async throws {
    let (json, data) = try await requestSessionRaw(["redirectURL": redirectURL])
    guard let sessionKey = json["sessionKey"] as? String,
          let accessToken = json["accessToken"] as? String
    else {
      Diag.log("getSessionForPC[redirectURL] 缺会话字段: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
      let why = (json["res_message"] as? String) ?? (json["message"] as? String) ?? ""
      throw Cloud189Error.loginFailed("会话获取失败：\(why)")
    }
    Diag.log("getSessionForPC[redirectURL] ok key=\(sessionKey.prefix(8))… token=\(accessToken.prefix(8))…")
    setSession(
      Session(
        sessionKey: sessionKey,
        accessToken: accessToken,
        refreshToken: json["refreshToken"] as? String,
        expiresAt: Date.now.addingTimeInterval(6 * 24 * 3600),
        loginName: json["loginName"] as? String
      )
    )
    saveSession()
    // 数据接口只认二次换取的正式会话（桌面版 getSession→loginByAccessToken）；
    // 失败不阻断登录，留给 apiGet 的 InvalidAccessToken 自愈兜底
    try? await reloginByAccessToken()
  }

  /// 用 accessToken 再换正式会话（桌面版 loginByAccessToken）。
  /// 该响应只取 sessionKey——accessToken 由 swap 换 API 专用令牌，桌面版同样不用它
  private func reloginByAccessToken() async throws {
    await Self.throttle.wait()
    guard let accessToken = session?.accessToken else {
      Diag.log("relogin: 无 accessToken")
      throw Cloud189Error.authExpired
    }
    let (json, data) = try await requestSessionRaw(["accessToken": accessToken])
    guard let sessionKey = json["sessionKey"] as? String else {
      Diag.log("relogin 响应缺 sessionKey: \(String(data: data.prefix(300), encoding: .utf8) ?? "?")")
      throw Cloud189Error.loginFailed("正式会话换取失败")
    }
    Diag.log("relogin ok key=\(sessionKey.prefix(8))…")
    if var current = session {
      current.sessionKey = sessionKey
      setSession(current)
      saveSession()
    }
  }

  // MARK: - 账号密码登录

  /// 取登录页参数（含验证码 token；验证码图片用 fetchCaptchaImage 展示）
  func fetchLoginForm() async throws -> LoginFormParams {
    try await fetchLoginPageParams()
  }

  /// 图形验证码图片（点击可换新图；须带 Referer，否则返回空体）
  func fetchCaptchaImage(captchaToken: String) async throws -> Data {
    var components = URLComponents(url: Self.authBase.appendingPathComponent("api/logbox/oauth2/picCaptcha.do"), resolvingAgainstBaseURL: false)!
    components.queryItems = [
      URLQueryItem(name: "token", value: captchaToken),
      URLQueryItem(name: "rnd", value: String(Int(Date().timeIntervalSince1970 * 1000))),
    ]
    var req = URLRequest(url: components.url!)
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://open.e.189.cn/", forHTTPHeaderField: "Referer")
    let (data, response) = try await URLSession.shared.data(for: req)
    guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
      throw Cloud189Error.loginFailed("验证码获取失败")
    }
    return data
  }

  /// 账号密码登录：RSA 加密 → loginSubmit → toUrl 换会话；服务器业务错误原样透传
  func loginByPassword(_ params: LoginFormParams, username: String, password: String, captcha: String) async throws {
    await Self.throttle.wait()
    // 1. 加密公钥与随机前缀
    var eReq = URLRequest(url: Self.authBase.appendingPathComponent("api/logbox/config/encryptConf.do"))
    eReq.httpMethod = "POST"
    eReq.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    eReq.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    let (eData, _) = try await URLSession.shared.data(for: eReq)
    guard let eJson = (try? JSONSerialization.jsonObject(with: eData)) as? [String: Any] else {
      throw Cloud189Error.loginFailed("加密参数获取失败")
    }
    let conf = eJson["data"] as? [String: Any] ?? eJson
    guard let pubKey = conf["pubKey"] as? String, let pre = conf["pre"] as? String,
          let userEnc = Self.rsaEncryptHex(pubKey, username),
          let passEnc = Self.rsaEncryptHex(pubKey, password)
    else { throw Cloud189Error.loginFailed("密码加密失败") }

    // 2. 提交登录
    var req = URLRequest(url: Self.authBase.appendingPathComponent("api/logbox/oauth2/loginSubmit.do"))
    req.httpMethod = "POST"
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://open.e.189.cn", forHTTPHeaderField: "Referer")
    req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    req.setValue(params.lt, forHTTPHeaderField: "lt")
    req.setValue(params.reqId, forHTTPHeaderField: "REQID")
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Self.formEncode([
      "appKey": Self.appId,
      "accountType": Self.accountType,
      "validateCode": captcha,
      "captchaToken": params.captchaToken,
      "dynamicCheck": "FALSE",
      "clientType": "1",
      "cb_SaveName": "3",
      "isOauth2": "false",
      "returnUrl": Self.returnUrl,
      "paramId": params.paramId,
      "userName": pre + userEnc,
      "password": pre + passEnc,
    ])
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw Cloud189Error.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, String(data: data.prefix(120), encoding: .utf8) ?? "")
    }
    if let toUrl = json["toUrl"] as? String, !toUrl.isEmpty {
      Diag.log("loginSubmit ok → exchange")
      try await exchangeSession(redirectURL: toUrl)
      return
    }
    // 3. 业务错误原样透传（如"图形验证码错误，请重新输入"/"账号或密码错误"）
    let msg = (json["msg"] as? String)
      ?? (json["errorMsg"] as? String)
      ?? "登录失败（result=\(json["result"] ?? "-")）"
    Diag.log("loginSubmit 失败: \(msg)")
    throw Cloud189Error.loginFailed(msg)
  }

  /// RSA PKCS#1 v1.5 加密，输出 hex；公钥为 SPKI DER 的 base64（PEM 主体）
  nonisolated private static func rsaEncryptHex(_ publicKeyBase64: String, _ text: String) -> String? {
    guard let der = Data(base64Encoded: publicKeyBase64, options: [.ignoreUnknownCharacters]) else { return nil }
    // SPKI ::= SEQUENCE { AlgorithmIdentifier, BIT STRING { RSAPublicKey } }，剥出内层 PKCS#1
    func tlv(_ data: Data, offset: inout Int) -> (tag: Int, content: Data)? {
      guard offset + 2 <= data.count else { return nil }
      let tag = Int(data[data.startIndex + offset]); offset += 1
      var length = Int(data[data.startIndex + offset]); offset += 1
      if length & 0x80 != 0 {
        let count = length & 0x7f
        length = 0
        for _ in 0..<count {
          guard offset < data.count else { return nil }
          length = length << 8 | Int(data[data.startIndex + offset]); offset += 1
        }
      }
      guard offset + length <= data.count else { return nil }
      let content = data.subdata(in: data.startIndex + offset..<data.startIndex + offset + length)
      offset += length
      return (tag, content)
    }
    var outerOffset = 0
    guard let spki = tlv(der, offset: &outerOffset), spki.tag == 0x30 else { return nil }
    var innerOffset = 0
    guard let algorithm = tlv(spki.content, offset: &innerOffset), algorithm.tag == 0x30,
          let keyBits = tlv(spki.content, offset: &innerOffset), keyBits.tag == 0x03 else { return nil }
    var pkcs1 = keyBits.content
    if pkcs1.first == 0x00 { pkcs1 = Data(pkcs1.dropFirst()) } // 首字节是未用位数
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(pkcs1 as CFData,
                                         [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                          kSecAttrKeyClass as String: kSecAttrKeyClassPublic] as CFDictionary,
                                         &error),
          let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(text.utf8) as CFData, &error) else {
      return nil
    }
    return (cipher as Data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - 会话恢复与刷新

  /// 确保会话可用（accessToken 过期时用 refreshToken 刷新）。
  /// 并发调用共享同一个刷新任务，避免两个请求同时刷新把 refreshToken 用废。
  func ensureSession() async throws {
    if let current = session, current.expiresAt > .now { return }
    let task: Task<Session, Error> = sessionLock.withLock {
      if let existing = refreshTask { return existing }
      let created = Task { try await self.performRefresh() }
      refreshTask = created
      return created
    }
    do {
      let refreshed = try await task.value
      sessionLock.withLock {
        storedSession = refreshed
        refreshTask = nil
      }
      saveSession()
    } catch {
      sessionLock.withLock {
        storedSession = nil
        refreshTask = nil
      }
      saveSession()
      throw error
    }
  }

  private func performRefresh() async throws -> Session {
    guard var current = session, let refresh = current.refreshToken else {
      throw Cloud189Error.authExpired
    }
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
      Diag.log("OAuth refreshToken.do 失败: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
      throw Cloud189Error.authExpired
    }
    current.accessToken = token
    current.refreshToken = json["refreshToken"] as? String ?? current.refreshToken
    if let seconds = json["expiresIn"] as? Double {
      current.expiresAt = .now.addingTimeInterval(seconds)
    } else {
      current.expiresAt = .now.addingTimeInterval(6 * 24 * 3600)
    }
    return current
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
    req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    req.setValue("1", forHTTPHeaderField: "Sign-Type")
    req.setValue(session.accessToken, forHTTPHeaderField: "Accesstoken")
    req.setValue(ts, forHTTPHeaderField: "Timestamp")
    req.setValue(signature, forHTTPHeaderField: "Signature")

    let (data, response) = try await URLSession.shared.data(for: req)
    let http = response as? HTTPURLResponse
    let body = String(data: data, encoding: .utf8) ?? ""

    // 会话失效自愈（对齐桌面版）：sessionKey 换 API 令牌 → 重换正式会话 → OAuth 刷新后再各来一次
    if http?.statusCode == 400, body.contains("InvalidAccessToken"), !retried {
      Diag.log("apiGet \(path) InvalidAccessToken，token=\(session.accessToken.prefix(10))… key=\(session.sessionKey.prefix(8))… 开始自愈")
      if (try? await swapAccessTokenBySessionKey()) == nil {
        try? await reloginByAccessToken()
        if (try? await swapAccessTokenBySessionKey()) == nil {
          do {
            try await ensureSession(force: true)
            try? await reloginByAccessToken()
            _ = try? await swapAccessTokenBySessionKey()
          } catch {
            Diag.log("自愈 OAuth 刷新失败: \(error.localizedDescription)")
          }
        }
      }
      Diag.log("自愈结束，重试 \(path)")
      return try await apiGet(path, params: params, retried: true)
    }
    if body.contains("RatesExceed") || http?.statusCode == 429 {
      throw Cloud189Error.ratesExceeded
    }
    guard (http?.statusCode ?? 500) == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      Diag.log("apiGet \(path) 失败 HTTP \(http?.statusCode ?? -1): \(body.prefix(200))")
      throw Cloud189Error.badStatus(http?.statusCode ?? -1, String(body.prefix(120)))
    }
    if let errorCode = json["errorCode"] as? String, errorCode.contains("InvalidSession") {
      throw Cloud189Error.authExpired
    }
    return json
  }

  private func ensureSession(force: Bool) async throws {
    if force {
      sessionLock.withLock { storedSession?.expiresAt = .distantPast }
    }
    try await ensureSession()
  }

  /// 用 sessionKey 换数据接口专用的 accessToken（/open 接口须带 appKey 签名，对齐 SDK signatureAppKey）
  private func swapAccessTokenBySessionKey() async throws -> String? {
    await Self.throttle.wait()
    guard let sessionKey = session?.sessionKey else { return nil }
    let ts = String(Int(Date().timeIntervalSince1970 * 1000))
    let signature = Self.md5Signature(["Timestamp": ts, "AppKey": Self.webAppKey])
    var components = URLComponents(url: Self.webBase.appendingPathComponent("api/open/oauth2/getAccessTokenBySsKey.action"), resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "sessionKey", value: sessionKey)]
    var req = URLRequest(url: components.url!)
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://cloud.189.cn/web/main/", forHTTPHeaderField: "Referer")
    req.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Accept")
    req.setValue("1", forHTTPHeaderField: "Sign-Type")
    req.setValue(Self.webAppKey, forHTTPHeaderField: "AppKey")
    req.setValue(ts, forHTTPHeaderField: "Timestamp")
    req.setValue(signature, forHTTPHeaderField: "Signature")
    let (data, _) = try await URLSession.shared.data(for: req)
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let token = json["accessToken"] as? String, !token.isEmpty
    else {
      Diag.log("swap 失败: \(String(data: data.prefix(200), encoding: .utf8) ?? "?")")
      return nil
    }
    Diag.log("swap ok token=\(token.prefix(8))…")
    if var current = session {
      current.accessToken = token
      setSession(current)
      saveSession()
    }
    return token
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
  func downloadURL(fileId: String, familyId: String?, forceRefresh: Bool = false) async throws -> URL {
    if !forceRefresh, let cached = cachedDownloadURL(fileId, familyId) {
      return cached
    }
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
      Diag.log("downloadURL[\(path)] 未取得地址: \(json.keys.sorted().joined(separator: ","))")
      throw Cloud189Error.badStatus(0, "未取得下载地址")
    }
    // 直链里 & 是 &amp;，不解码请求必 403
    let decoded = raw
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
    guard let url = URL(string: decoded) else {
      Diag.log("downloadURL[\(path)] 地址无效: \(raw.prefix(120))")
      throw Cloud189Error.badStatus(0, "下载地址无效")
    }
    Diag.log("downloadURL[\(path)] \(url.scheme ?? "?")://\(url.host ?? "?")")
    storeDownloadURL(url, fileId: fileId, familyId: familyId)
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
        invalidateDownloadURL(fileId: fileId, familyId: familyId)
      }
    }
    throw lastError ?? Cloud189Error.badStatus(0, "下载失败")
  }

  /// 拉一小段数据（散图单张）。直链过期（403/410）自动换新重试一次。
  func fetchData(fileId: String, familyId: String?, sizeLimit: Int? = nil) async throws -> Data {
    do {
      return try await fetchDataOnce(fileId: fileId, familyId: familyId, sizeLimit: sizeLimit)
    } catch let error as Cloud189Error {
      guard case .badStatus(let code, _) = error, code == 401 || code == 403 || code == 410 else { throw error }
      invalidateDownloadURL(fileId: fileId, familyId: familyId)
      return try await fetchDataOnce(fileId: fileId, familyId: familyId, sizeLimit: sizeLimit)
    }
  }

  /// 传 sizeLimit 时先落临时文件检查大小，避免大包占满内存。
  private func fetchDataOnce(fileId: String, familyId: String?, sizeLimit: Int? = nil) async throws -> Data {
    var url = try await downloadURL(fileId: fileId, familyId: familyId)
    // 直链是 http，升级到 https（CDN 支持且验证过），绕开 ATS 对明文的拦截
    if url.scheme == "http", var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      comps.scheme = "https"
      if let upgraded = comps.url {
        Diag.log("直链升级 https")
        url = upgraded
      }
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 30
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://cloud.189.cn/web/main/", forHTTPHeaderField: "Referer")
    if let sizeLimit {
      let (tmp, response) = try await URLSession.shared.download(for: req)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        Diag.log("fetchData \(fileId) 大包 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        throw Cloud189Error.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "取文件失败")
      }
      let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      guard size > 0, size <= sizeLimit else {
        try? FileManager.default.removeItem(at: tmp)
        throw Cloud189Error.badStatus(0, "文件超过 \(sizeLimit / (1024 * 1024)) MB，无法无盘打开")
      }
      let data = try Data(contentsOf: tmp)
      try? FileManager.default.removeItem(at: tmp)
      return data
    }
    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        Diag.log("fetchData \(fileId) HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1): \(String(data: data.prefix(200), encoding: .utf8) ?? "<\(data.count)字节>")")
        throw Cloud189Error.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "取图失败")
      }
      return data
    } catch let error as Cloud189Error {
      throw error
    } catch {
      Diag.log("fetchData \(fileId) 网络: \(error.localizedDescription)")
      throw error
    }
  }

  /// 只取文件开头一段（读图片尺寸用），避免为拿宽高下载整页大图。
  func fetchPrefix(fileId: String, familyId: String?, length: Int) async throws -> Data {
    do {
      return try await fetchPrefixOnce(fileId: fileId, familyId: familyId, length: length)
    } catch let error as Cloud189Error {
      guard case .badStatus(let code, _) = error, code == 401 || code == 403 || code == 410 else { throw error }
      invalidateDownloadURL(fileId: fileId, familyId: familyId)
      return try await fetchPrefixOnce(fileId: fileId, familyId: familyId, length: length)
    }
  }

  private func fetchPrefixOnce(fileId: String, familyId: String?, length: Int) async throws -> Data {
    guard length > 0 else { return Data() }
    var url = try await downloadURL(fileId: fileId, familyId: familyId)
    if url.scheme == "http", var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
      comps.scheme = "https"
      if let upgraded = comps.url { url = upgraded }
    }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("https://cloud.189.cn/web/main/", forHTTPHeaderField: "Referer")
    req.setValue("bytes=0-\(length - 1)", forHTTPHeaderField: "Range")
    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse,
          http.statusCode == 206 || http.statusCode == 200 else {
      throw Cloud189Error.badStatus((response as? HTTPURLResponse)?.statusCode ?? -1, "取图头失败")
    }
    return data.count > length ? Data(data.prefix(length)) : data
  }

  /// 后台加载线程的同步取图头（页源用）
  nonisolated func fetchPrefixSync(fileId: String, familyId: String?, length: Int) -> Data? {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: Data?
    Task.detached {
      result = try? await self.fetchPrefix(fileId: fileId, familyId: familyId, length: length)
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }
}

// MARK: - 最小间隔串行闸（300ms，防风控）

actor MinInterval {
  private let interval: TimeInterval
  private var nextAllowed = Date.distantPast

  init(milliseconds: Int) {
    interval = Double(milliseconds) / 1000
  }

  func wait() async {
    // 先占住时间槽再 sleep：actor 在 await 处可重入，否则并发调用会同时放行。
    let now = Date.now
    let slot = max(now, nextAllowed)
    nextAllowed = slot.addingTimeInterval(interval)
    if slot > now {
      try? await Task.sleep(for: .seconds(slot.timeIntervalSince(now)))
    }
  }
}
