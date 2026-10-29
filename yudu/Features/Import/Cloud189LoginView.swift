import SwiftUI
import CoreImage.CIFilterBuiltins

/// 天翼云盘：扫码登录 → 浏览目录 → 挂载
struct Cloud189LoginView: View {
  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss

  enum Phase {
    case qr
    case browse
  }

  @State private var phase: Phase = .qr
  @State private var client = Cloud189Client()
  @State private var qrImage: UIImage?
  @State private var qrLogin: Cloud189Client.QRLogin?
  @State private var statusText = "正在获取二维码…"
  @State private var pollTask: Task<Void, Never>?

  // 浏览态
  @State private var families: [(familyId: String, name: String)] = []
  @State private var scopeFamilyId: String?
  @State private var path: [Cloud189Item] = []
  @State private var items: [Cloud189Item] = []
  @State private var busy = false
  @State private var message: String?

  // 账号密码登录
  @State private var showPasswordLogin = false
  @State private var loginForm: Cloud189Client.LoginFormParams?
  @State private var username = ""
  @State private var password = ""
  @State private var captchaInput = ""
  @State private var captchaImage: UIImage?
  @State private var pwBusy = false
  @State private var pwError: String?

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .qr:
          ScrollView {
            VStack(spacing: 22) {
              if showPasswordLogin {
                passwordForm
              } else {
                qrContent
              }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 20)
          }
        case .browse:
          List {
            scopePicker
            Section {
              if path.last != nil {
                Button {
                  path.removeLast()
                  let target = path.last
                  Task { await load(folderId: target?.id ?? rootFolderId) }
                } label: {
                  Label("上一级", systemImage: "arrow.up")
                }
              }
              if !busy && items.isEmpty {
                Text("此目录为空，可返回上一级或切换云空间。")
                  .font(.subheadline).foregroundStyle(YuduTheme.muted)
              }
              ForEach(items.filter(\.isDirectory), id: \.id) { item in
                Button {
                  path.append(item)
                  Task { await load(folderId: item.id) }
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
          .overlay { if busy { ProgressView() } }
        }
      }
      .yuduPage()
      .navigationTitle(phase == .qr ? "天翼云盘" : (path.last?.name ?? "天翼云盘"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") {
            pollTask?.cancel()
            dismiss()
          }.disabled(busy)
        }
        if phase == .browse {
          ToolbarItem(placement: .topBarLeading) {
            Button("退出登录") { logoutAndReset() }
              .disabled(busy)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if phase == .browse {
            Button("添加此文件夹") { mount() }
              .disabled(busy)
          }
        }
      }
      .alert("无法读取或添加书库", isPresented: Binding(
        get: { message != nil },
        set: { if !$0 { message = nil } }
      )) {
        Button("好") { message = nil }
      } message: {
        Text(message ?? "")
      }
    }
    .onAppear {
      if client.isLoggedIn {
        Task {
          do {
            try await client.ensureSession()
            await enterBrowse()
          } catch {
            // 会话已失效：清掉钥匙串并回到扫码，否则过期会话会让页面永远进不了登录。
            client.logout()
            startQRLogin()
          }
        }
      } else {
        startQRLogin()
      }
    }
    .onDisappear { pollTask?.cancel() }
    .interactiveDismissDisabled(busy)
  }

  // MARK: - 登录页两种形态

  private var qrContent: some View {
    VStack(spacing: 22) {
      VStack(spacing: 10) {
        Image(systemName: "icloud.fill")
          .font(.system(size: 26))
          .foregroundStyle(YuduTheme.violet)
          .frame(width: 62, height: 62)
          .background(
            YuduTheme.violet.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 16)
          )
          .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(YuduTheme.violet.opacity(0.4), lineWidth: 1) }
        Text("登录天翼云盘")
          .font(.headline)
        Text("用手机天翼云盘 App 扫一扫并确认")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Group {
        if let qrImage {
          Image(uiImage: qrImage)
            .interpolation(.none)
            .resizable()
            .scaledToFit()
            .padding(14)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        } else {
          RoundedRectangle(cornerRadius: 16)
            .fill(YuduTheme.surface)
            .overlay(ProgressView())
        }
      }
      .frame(width: 236, height: 236)

      Text(statusText)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(YuduTheme.surface, in: Capsule())

      Button {
        startQRLogin()
      } label: {
        Label("刷新二维码", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)

      Button("使用账号密码登录") {
        startPasswordLogin()
      }
      .font(.footnote)

      Text("登录凭证保存在本机钥匙串")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private var passwordForm: some View {
    VStack(spacing: 14) {
      Text("账号密码登录")
        .font(.headline)
      TextField("手机号 / 邮箱 / 用户名", text: $username)
        .textFieldStyle(.roundedBorder)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      SecureField("密码", text: $password)
        .textFieldStyle(.roundedBorder)
      HStack(spacing: 10) {
        TextField("验证码", text: $captchaInput)
          .textFieldStyle(.roundedBorder)
        Group {
          if let captchaImage {
            Image(uiImage: captchaImage)
              .resizable()
              .scaledToFit()
          } else {
            ZStack {
              RoundedRectangle(cornerRadius: 6)
                .fill(.white)
              ProgressView()
            }
          }
        }
        .frame(width: 118, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
          Task { await refreshCaptcha() }
        }
      }
      if let pwError {
        Text(pwError)
          .font(.footnote)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      Button {
        submitPasswordLogin()
      } label: {
        Group {
          if pwBusy {
            ProgressView()
          } else {
            Text("登录")
          }
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .disabled(pwBusy || username.isEmpty || password.isEmpty || loginForm == nil)
      Button("返回扫码登录") {
        showPasswordLogin = false
        startQRLogin()
      }
      .font(.footnote)
    }
  }

  // MARK: - 扫码

  private func startQRLogin() {
    pollTask?.cancel()
    qrImage = nil
    statusText = "正在获取二维码…"
    pollTask = Task {
      do {
        let login = try await client.beginQRLogin()
        guard !Task.isCancelled else { return }
        qrLogin = login
        qrImage = Self.makeQRCode(text: login.uuid)
        statusText = "打开天翼云盘 App 扫码登录"
        startPolling()
      } catch {
        statusText = error.localizedDescription
      }
    }
  }

  private func startPolling() {
    pollTask?.cancel()
    pollTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(2.5))
        guard !Task.isCancelled else { return }
        guard let login = qrLogin else { return }
        do {
          switch try await client.pollQRLogin(login) {
          case .waiting:
            break // 保持“打开天翼云盘 App 扫码登录”文案
          case .scanned:
            statusText = "已扫码，请在天翼云盘 App 里确认登录"
          case .confirmed:
            guard !Task.isCancelled else { return }
            statusText = "登录成功"
            await enterBrowse()
            return
          case .expired:
            statusText = "二维码已过期，请刷新"
            return
          }
        } catch {
          // 失败必须可见（如换会话失败），否则会看起来卡死；继续轮询让瞬断可自愈
          statusText = error.localizedDescription
        }
      }
    }
  }

  // MARK: - 账号密码

  private func startPasswordLogin() {
    pollTask?.cancel()
    showPasswordLogin = true
    username = ""
    password = ""
    captchaInput = ""
    captchaImage = nil
    loginForm = nil
    pwError = nil
    Task {
      do {
        loginForm = try await client.fetchLoginForm()
        await refreshCaptcha()
      } catch {
        pwError = error.localizedDescription
      }
    }
  }

  private func refreshCaptcha() async {
    guard let token = loginForm?.captchaToken else { return }
    do {
      captchaImage = UIImage(data: try await client.fetchCaptchaImage(captchaToken: token))
    } catch {
      pwError = error.localizedDescription
    }
  }

  private func submitPasswordLogin() {
    guard let form = loginForm, !pwBusy else { return }
    pwBusy = true
    pwError = nil
    Task {
      defer { pwBusy = false }
      do {
        try await client.loginByPassword(form, username: username, password: password, captcha: captchaInput)
        statusText = "登录成功"
        await enterBrowse()
      } catch {
        // 服务器业务错误原样透传（"图形验证码错误"/"账号或密码错误"…），验证码换新图
        pwError = error.localizedDescription
        captchaInput = ""
        await refreshCaptcha()
      }
    }
  }

  // MARK: - 浏览

  private var rootFolderId: String { "-11" }

  private func enterBrowse() async {
    busy = true
    defer { busy = false }
    do {
      families = try await client.familyList()
    } catch let error as Cloud189Client.Cloud189Error {
      if case .authExpired = error {
        Diag.log("enterBrowse authExpired → 回扫码页")
        client.logout()
        phase = .qr
        startQRLogin()
        return
      }
      message = error.localizedDescription
    } catch {
      message = error.localizedDescription
    }
    phase = .browse
    await load(folderId: rootFolderId)
  }

  private func logoutAndReset() {
    pollTask?.cancel()
    pollTask = nil
    client.logout()
    families = []
    items = []
    path = []
    scopeFamilyId = nil
    qrImage = nil
    qrLogin = nil
    showPasswordLogin = false
    phase = .qr
    statusText = "正在获取二维码…"
    startQRLogin()
  }

  private var currentFolderId: String {
    path.last?.id ?? rootFolderId
  }

  private func load(folderId: String) async {
    busy = true
    defer { busy = false }
    items = []
    do { items = try await client.listFiles(folderId: folderId, familyId: scopeFamilyId) }
    catch { message = error.localizedDescription }
  }

  private var scopePicker: some View {
    Picker("空间", selection: Binding(
      get: { scopeFamilyId },
      set: { newValue in
        scopeFamilyId = newValue
        path = []
        Task { await load(folderId: rootFolderId) }
      }
    )) {
      Text("个人云").tag(String?.none)
      ForEach(families, id: \.familyId) { family in
        Text(family.name).tag(String?.some(family.familyId))
      }
    }
    .pickerStyle(.segmented)
    .listRowBackground(Color.clear)
  }

  private func mount() {
    busy = true
    let folderId = currentFolderId
    let familyId = scopeFamilyId
    let name = path.last?.name ?? (familyId == nil ? "天翼云盘" : "家庭云")
    Task {
      let result = await libraryService.addCloud189Library(
        folderId: folderId, familyId: familyId, name: name
      )
      busy = false
      switch result {
      case .success:
        dismiss()
      case .failure(let failure):
        message = failure.message
      }
    }
  }

  // MARK: - 二维码生成（uuid 字符串自渲染，官方 image.do 可省）

  static func makeQRCode(text: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.scaled(10) else { return nil }
    let context = CIContext()
    guard let cg = context.createCGImage(output, from: output.extent) else { return nil }
    return UIImage(cgImage: cg)
  }
}

extension CIImage {
  func scaled(_ factor: CGFloat) -> CIImage {
    transformed(by: CGAffineTransform(scaleX: factor, y: factor))
  }
}
