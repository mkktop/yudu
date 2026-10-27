import Foundation

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
