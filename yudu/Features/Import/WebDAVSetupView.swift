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

  private var validatedAddress: URL? { WebDAVAddress.parse(address) }
  private var currentURL: URL? { path.last?.url ?? validatedAddress }

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .form:
          Form {
            Section {
              VStack(spacing: 10) {
                Image(systemName: "cloud.fill")
                  .font(.system(size: 26))
                  .foregroundStyle(YuduTheme.violet)
                  .frame(width: 62, height: 62)
                  .background(
                    YuduTheme.violet.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 16)
                  )
                  .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(YuduTheme.violet.opacity(0.4), lineWidth: 1) }
                Text("连接 WebDAV 服务器")
                  .font(.headline)
                Text("支持坚果云、NAS 等标准 WebDAV\n填写漫画所在目录的地址")
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .multilineTextAlignment(.center)
              }
              .frame(maxWidth: .infinity)
              .padding(.vertical, 10)
              .listRowBackground(Color.clear)
            }

            Section {
              HStack(spacing: 10) {
                Image(systemName: "link")
                  .foregroundStyle(.secondary)
                  .frame(width: 22)
                TextField("服务器地址", text: $address)
                  .keyboardType(.URL)
                  .autocorrectionDisabled()
                  .textInputAutocapitalization(.never)
              }
              if let url = validatedAddress, url.scheme?.lowercased() == "http" {
                Label("HTTP 明文传输不加密，建议只在可信局域网使用", systemImage: "exclamationmark.triangle")
                  .font(.caption)
                  .foregroundStyle(.orange)
              }
              HStack(spacing: 10) {
                Image(systemName: "person")
                  .foregroundStyle(.secondary)
                  .frame(width: 22)
                TextField("用户名（可选）", text: $username)
                  .autocorrectionDisabled()
                  .textInputAutocapitalization(.never)
              }
              HStack(spacing: 10) {
                Image(systemName: "lock")
                  .foregroundStyle(.secondary)
                  .frame(width: 22)
                SecureField("密码 / 应用密码（可选）", text: $password)
              }
            }

            Section {
              Button {
                Task { await primaryAction() }
              } label: {
                HStack(spacing: 8) {
                  if busy {
                    ProgressView()
                      .tint(YuduTheme.background)
                  }
                  Text("连接服务器")
                    .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
              }
              .buttonStyle(OrbitalButtonStyle())
              .disabled(busy || validatedAddress == nil)
              .listRowInsets(EdgeInsets())
              .listRowBackground(Color.clear)
            }

            if let message {
              Section {
                Label(message, systemImage: message.contains("成功") ? "checkmark.circle" : "exclamationmark.triangle")
                  .foregroundStyle(message.contains("成功") ? .green : .orange)
                  .font(.subheadline)
              }
            }
          }
          .scrollContentBackground(.hidden)
        case .browse:
          List {
            Section {
              if !path.isEmpty {
                Button {
                  path.removeLast()
                  if let target = currentURL { Task { await load(url: target) } }
                } label: {
                  Label("上一级", systemImage: "arrow.up")
                }
              }
              if !busy && items.isEmpty {
                Text("此目录为空，可返回上一级选择漫画文件夹。")
                  .font(.subheadline).foregroundStyle(YuduTheme.muted)
              }
              ForEach(items.filter(\.isDirectory), id: \.url) { item in
                Button {
                  path.append(item)
                  Task { await load(url: item.url) }
                } label: {
                  HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                      .foregroundStyle(YuduTheme.accent)
                    Text(item.name)
                      .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                      .font(.caption.weight(.semibold))
                      .foregroundStyle(.tertiary)
                  }
                }
              }
            } footer: {
              let loose = items.filter { $0.isArchive || $0.isPDF }.count
              if loose > 0 {
                Text("此处有 \(loose) 个压缩包 / PDF，可直接挂载")
              }
            }
          }
          .scrollContentBackground(.hidden)
          .disabled(busy)
          .overlay {
            if busy {
              ProgressView()
            }
          }
        }
      }
      .yuduPage()
      .navigationTitle(phase == .form ? "连接 WebDAV" : (path.last?.name ?? "根目录"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { dismiss() }.disabled(busy)
        }
        if phase == .browse {
          ToolbarItem(placement: .confirmationAction) {
            Button("添加此文件夹") {
              Task { await primaryAction() }
            }
            .disabled(busy)
          }
        }
      }
      .alert("无法读取或添加书库", isPresented: Binding(
        get: { phase == .browse && message != nil },
        set: { if !$0 { message = nil } }
      )) {
        Button("好") { message = nil }
      } message: {
        Text(message ?? "")
      }
    }
    .interactiveDismissDisabled(busy)
  }

  private func load(url: URL) async {
    busy = true
    defer { busy = false }
    let probe = WebDAVClient(baseURL: url, username: username, password: password)
    message = nil
    items = []
    do { items = try await probe.list(url) }
    catch { message = error.localizedDescription }
  }

  private func primaryAction() async {
    guard let url = currentURL else {
      message = "地址无效"
      return
    }
    busy = true
    message = nil
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
      case .success:
        dismiss()
      case .failure(let failure):
        message = failure.message
      }
    }
  }
}
