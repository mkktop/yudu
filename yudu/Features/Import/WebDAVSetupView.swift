import SwiftUI

/// WebDAV 连接向导：填地址账号 → 验证 → 逐层浏览 → 挂载当前文件夹为书库
struct WebDAVSetupView: View {
  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss

  @State private var address = "https://"
  @State private var username = ""
  @State private var password = ""
  @State private var phase: Phase = .form
  @State private var message: String?
  @State private var busy = false
  @State private var path: [WebDAVItem] = []
  @State private var items: [WebDAVItem] = []

  enum Phase {
    case form
    case browse
  }

  private var currentURL: URL? {
    guard var url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return nil }
    if url.scheme == nil {
      guard let withScheme = URL(string: "https://" + url.absoluteString) else { return nil }
      url = withScheme
    }
    // 逐层下钻后，当前目录 = 最后进入的子项 URL
    if let deepest = path.last {
      return deepest.url
    }
    return url
  }

  private var client: WebDAVClient? {
    guard let url = currentURL else { return nil }
    return WebDAVClient(baseURL: url, username: username, password: password)
  }

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .form:
          Form {
            Section {
              TextField("服务器地址", text: $address)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
              TextField("用户名（可选）", text: $username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
              SecureField("密码 / 应用密码（可选）", text: $password)
            } header: {
              Text("WebDAV 服务器")
            } footer: {
              Text("支持坚果云、NAS 等标准 WebDAV；填漫画所在的目录地址。")
            }
            if let message {
              Section {
                Label(message, systemImage: message.contains("成功") ? "checkmark.circle" : "exclamationmark.triangle")
                  .foregroundStyle(message.contains("成功") ? .green : .orange)
                  .font(.subheadline)
              }
            }
          }
        case .browse:
          List {
            if !path.isEmpty {
              Button {
                path.removeLast()
                let target = path.last?.url ?? currentURL
                if let target {
                  Task { await load(url: target) }
                }
              } label: {
                Label("上一级", systemImage: "arrow.up")
              }
            }
            ForEach(items.filter(\.isDirectory), id: \.url) { item in
              Button {
                path.append(item)
                Task { await load(url: item.url) }
              } label: {
                Label(item.name, systemImage: "folder")
              }
            }
            let loose = items.filter { $0.isArchive || $0.isPDF }.count
            if loose > 0 {
              Text("此处有 \(loose) 个压缩包 / PDF，可直接挂载")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .overlay {
            if busy {
              ProgressView()
            }
          }
        }
      }
      .navigationTitle(phase == .form ? "连接 WebDAV" : (path.last?.name ?? "根目录"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(phase == .form ? "连接" : "挂载此文件夹") {
            Task { await primaryAction() }
          }
          .disabled(busy || (phase == .form && address.count < 8))
        }
      }
    }
  }

  private func load(url: URL) async {
    busy = true
    defer { busy = false }
    let probe = WebDAVClient(baseURL: url, username: username, password: password)
    items = (try? await probe.list(url)) ?? []
    if items.isEmpty {
      message = "目录为空或读取失败"
    }
  }

  private func primaryAction() async {
    guard let url = currentURL else {
      message = "地址无效"
      return
    }
    busy = true
    defer { busy = false }

    if phase == .form {
      let probe = WebDAVClient(baseURL: url, username: username, password: password)
      do {
        items = try await probe.list(url)
        phase = .browse
        path = []
      } catch {
        message = error.localizedDescription
      }
    } else {
      // 挂载当前目录
      let result = await libraryService.addWebDAVLibrary(
        baseURL: url, username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password
      )
      switch result {
      case .success(let library):
        message = "已挂载「\(library.name)」"
        try? await Task.sleep(for: .seconds(0.6))
        dismiss()
      case .failure(let failure):
        message = failure.message
      }
    }
  }
}
