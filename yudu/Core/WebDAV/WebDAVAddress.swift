import Foundation

/// 同源判断：WebDAV 返回的 href 只能指向同一服务器，避免把 Basic 凭据发给恶意主机。
nonisolated enum WebDAVOrigin {
  static func isHTTP(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else { return false }
    return scheme == "http" || scheme == "https"
  }

  static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard isHTTP(lhs), isHTTP(rhs),
          let leftScheme = lhs.scheme?.lowercased(),
          let rightScheme = rhs.scheme?.lowercased(),
          leftScheme == rightScheme,
          let leftHost = lhs.host?.lowercased(),
          let rightHost = rhs.host?.lowercased(),
          leftHost == rightHost
    else { return false }
    return port(lhs, scheme: leftScheme) == port(rhs, scheme: rightScheme)
  }

  private static func port(_ url: URL, scheme: String) -> Int? {
    if let port = url.port { return port }
    return scheme == "https" ? 443 : 80
  }
}

/// 地址解析与 UI 分离，连接按钮只接受可用的 HTTP(S) 地址。
enum WebDAVAddress {
  static func parse(_ input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
    guard let components = URLComponents(string: normalized),
          let scheme = components.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          let host = components.host, !host.isEmpty,
          components.user == nil, components.password == nil,
          components.query == nil, components.fragment == nil else { return nil }
    return components.url
  }
}
