import SwiftUI
import SwiftData
import CoreImage.CIFilterBuiltins

/// 添加网盘账号（WebDAV / 天翼云盘），或对已有账号做编辑 / 重新登录。
/// 成功后通过 onFinished 回传账号（调用方负责 push 整盘浏览器）。
struct AddSourceSheet: View {
  /// 非 nil 时为「编辑 / 重新登录该账号」模式
  var existing: SourceEntity? = nil
  var onFinished: (SourceEntity) -> Void = { _ in }

  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss

  private enum Phase { case pick, webdav, cloud189 }
  @State private var phase: Phase = .pick

  // WebDAV 表单
  @State private var name = ""
  @State private var address = "https://"
  @State private var username = ""
  @State private var password = ""
  @State private var busy = false
  @State private var message: String?

  // 天翼：登录流绑定的账号（新建占位或 existing）
  @State private var cloudSource: SourceEntity?
  @State private var cloudCreatedHere = false
  /// 成功完成（保存/登录）后置 true；下滑关闭时据此判断是否要清理占位账号。
  @State private var finished = false

  private var title: String {
    switch phase {
    case .pick: "添加网盘"
    case .webdav: existing == nil ? "连接 WebDAV" : "编辑 WebDAV 账号"
    case .cloud189: existing == nil ? "登录天翼云盘" : "重新登录天翼云盘"
    }
  }

  private var validatedAddress: URL? { WebDAVAddress.parse(address) }

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .pick: pickPhase
        case .webdav: webdavPhase
        case .cloud189: cloud189Phase
        }
      }
      .yuduPage()
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("取消") { cancel() }.disabled(busy)
        }
      }
      .alert("无法完成操作", isPresented: Binding(
        get: { message != nil },
        set: { if !$0 { message = nil } }
      )) {
        Button("好") { message = nil }
      } message: {
        Text(message ?? "")
      }
    }
    .interactiveDismissDisabled(busy)
    .onDisappear { cleanupPlaceholderIfNeeded() }
    .onAppear {
      guard let existing else { return }
      switch existing.kind {
      case "webdav":
        phase = .webdav
        name = existing.name
        address = existing.baseURL ?? "https://"
        username = existing.username ?? ""
      case "cloud189":
        phase = .cloud189
        cloudSource = existing
      default:
        break
      }
    }
  }

  // MARK: - 类型选择

  private var pickPhase: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SectionHeading(title: "选择网盘类型", eyebrow: "ADD AN ACCOUNT")
        Text("每个账号登录一次、可导入多个文件夹；同一种网盘也能添加多个账号。")
          .font(.subheadline).foregroundStyle(YuduTheme.muted)
        entryCard(
          title: "WebDAV / NAS", caption: "坚果云、群晖、Alist 等，支持多账号",
          icon: "externaldrive.connected.to.line.below", tint: YuduTheme.violet
        ) { phase = .webdav }
        entryCard(
          title: "天翼云盘", caption: "扫码或账密登录 · 个人云与家庭云",
          icon: "cloud", tint: YuduTheme.violet
        ) { startCloud189() }
        Label("连接凭证保存在本机钥匙串，按账号隔离", systemImage: "lock.shield")
          .font(.caption2).foregroundStyle(YuduTheme.muted)
      }
      .padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func entryCard(title: String, caption: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon).font(.system(size: 22, weight: .light))
          .foregroundStyle(tint).frame(width: 46, height: 46)
          .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        VStack(alignment: .leading, spacing: 6) {
          Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(YuduTheme.text)
          Text(caption).font(.caption).foregroundStyle(YuduTheme.muted).multilineTextAlignment(.leading)
        }
        Spacer()
        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(tint)
      }
      .padding(16).yuduPanel()
    }
    .buttonStyle(.plain)
  }

  // MARK: - WebDAV

  private var webdavPhase: some View {
    Form {
      if existing == nil {
        Section {
          VStack(spacing: 10) {
            Image(systemName: "externaldrive.connected.to.line.below")
              .font(.system(size: 26))
              .foregroundStyle(YuduTheme.violet)
              .frame(width: 62, height: 62)
              .background(YuduTheme.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
              .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(YuduTheme.violet.opacity(0.4), lineWidth: 1) }
            Text("连接 WebDAV 服务器")
              .font(.headline)
            Text("支持坚果云、NAS 等标准 WebDAV\n登录后可整盘浏览，漫画目录随用随导")
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .listRowBackground(Color.clear)
        }
      }

      Section {
        HStack(spacing: 10) {
          Image(systemName: "link").foregroundStyle(.secondary).frame(width: 22)
          TextField("服务器地址", text: $address)
            .keyboardType(.URL)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .disabled(existing != nil)
        }
        if existing == nil, let url = validatedAddress, url.scheme?.lowercased() == "http" {
          Label("HTTP 明文传输不加密，建议只在可信局域网使用", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        HStack(spacing: 10) {
          Image(systemName: "person").foregroundStyle(.secondary).frame(width: 22)
          TextField("用户名（可选）", text: $username)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        HStack(spacing: 10) {
          Image(systemName: "lock").foregroundStyle(.secondary).frame(width: 22)
          SecureField(passwordHint, text: $password)
        }
        HStack(spacing: 10) {
          Image(systemName: "tag").foregroundStyle(.secondary).frame(width: 22)
          TextField("账号名称（可选，便于区分多个账号）", text: $name)
        }
      } header: {
        if existing != nil {
          Text("地址创建后不可修改；如需换服务器请添加新账号").textCase(nil)
            .font(.caption).foregroundStyle(YuduTheme.muted)
        }
      }

      Section {
        Button {
          Task { await submitWebDAV() }
        } label: {
          HStack(spacing: 8) {
            if busy { ProgressView().tint(YuduTheme.background) }
            Text(existing == nil ? "连接并保存" : "保存修改")
              .font(.subheadline.weight(.semibold))
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 4)
        }
        .buttonStyle(OrbitalButtonStyle())
        .disabled(busy || (existing == nil && validatedAddress == nil))
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }
    }
    .scrollContentBackground(.hidden)
  }

  private var passwordHint: String {
    existing == nil ? "密码 / 应用密码（可选）" : "新密码（留空保持原密码）"
  }

  private func submitWebDAV() async {
    busy = true
    message = nil
    defer { busy = false }
    if let source = existing {
      // 编辑：校验新凭据（密码留空沿用原密码），成功后更新账号
      guard let baseURL = source.baseURL.flatMap(URL.init(string:)) else {
        message = "账号配置无效"
        return
      }
      let probePassword = password.isEmpty ? Keychain.get(account: source.passwordAccount) : password
      let probe = WebDAVClient(baseURL: baseURL, username: username.isEmpty ? nil : username, password: probePassword)
      do {
        try await probe.verify()
      } catch {
        message = error.localizedDescription
        return
      }
      source.name = name.isEmpty ? source.name : name
      source.username = username.isEmpty ? nil : username
      if !password.isEmpty {
        Keychain.set(password, account: source.passwordAccount)
      }
      try? libraryService.modelContext.save()
      finished = true
      onFinished(source)
      dismiss()
    } else {
      switch await libraryService.createWebDAVSource(
        name: name, address: address,
        username: username.isEmpty ? nil : username,
        password: password.isEmpty ? nil : password
      ) {
      case .success(let source):
        finished = true
        onFinished(source)
        dismiss()
      case .failure(let failure):
        message = failure.message
      }
    }
  }

  // MARK: - 天翼云盘

  private var cloud189Phase: some View {
    Group {
      if let cloudSource {
        Cloud189LoginFlowView(client: libraryService.cloud189Client(for: cloudSource)) {
          finishCloud189Login()
        }
      } else {
        ProgressView()
      }
    }
  }

  private func startCloud189() {
    let source = libraryService.createCloud189Source()
    cloudSource = source
    cloudCreatedHere = true
    phase = .cloud189
  }

  private func finishCloud189Login() {
    guard let source = cloudSource else { return }
    let client = libraryService.cloud189Client(for: source)
    if let nickname = client.session?.loginName {
      source.username = nickname
      if source.name.isEmpty || source.name == "天翼云盘" {
        source.name = nickname
      }
    }
    try? libraryService.modelContext.save()
    finished = true
    cloudCreatedHere = false
    onFinished(source)
    dismiss()
  }

  /// 取消：新建的天翼占位账号（未登录成功）要清掉，避免留下空账号。
  /// 下滑关闭不会走 cancel()，所以 onDisappear 也要做同样的清理。
  private func cancel() {
    cleanupPlaceholderIfNeeded()
    dismiss()
  }

  private func cleanupPlaceholderIfNeeded() {
    guard !finished, cloudCreatedHere, let source = cloudSource else { return }
    cloudCreatedHere = false
    libraryService.removeSource(source)
  }
}

// MARK: - 天翼登录流（扫码 / 账号密码），从旧挂载向导迁移而来
//
// 会话写入 client 绑定的 Keychain 槽 = 目标账号；登录成功即回调。

struct Cloud189LoginFlowView: View {
  let client: Cloud189Client
  var onLoggedIn: () -> Void

  @State private var qrImage: UIImage?
  @State private var qrLogin: Cloud189Client.QRLogin?
  @State private var statusText = "正在获取二维码…"
  @State private var pollTask: Task<Void, Never>?

  @State private var showPasswordLogin = false
  @State private var username = ""
  @State private var password = ""
  @State private var captchaInput = ""
  @State private var captchaImage: UIImage?
  @State private var pwBusy = false
  @State private var pwError: String?
  @State private var loginForm: Cloud189Client.LoginFormParams?

  var body: some View {
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
    .onAppear {
      if client.isLoggedIn {
        Task {
          do {
            try await client.ensureSession()
            onLoggedIn()
          } catch {
            // 会话已失效：清掉钥匙串并回到扫码，否则过期会话会让页面进不了登录
            client.logout()
            startQRLogin()
          }
        }
      } else {
        startQRLogin()
      }
    }
    .onDisappear { pollTask?.cancel() }
  }

  // MARK: 两种登录形态

  private var qrContent: some View {
    VStack(spacing: 22) {
      VStack(spacing: 10) {
        Image(systemName: "icloud.fill")
          .font(.system(size: 26))
          .foregroundStyle(YuduTheme.violet)
          .frame(width: 62, height: 62)
          .background(YuduTheme.violet.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
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

  // MARK: 扫码


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
            break
          case .scanned:
            statusText = "已扫码，请在天翼云盘 App 里确认登录"
          case .confirmed:
            guard !Task.isCancelled else { return }
            statusText = "登录成功"
            onLoggedIn()
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

  // MARK: 账号密码

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
        onLoggedIn()
      } catch {
        // 服务器业务错误原样透传（"图形验证码错误"/"账号或密码错误"…），验证码换新图
        pwError = error.localizedDescription
        captchaInput = ""
        await refreshCaptcha()
      }
    }
  }

  // MARK: 二维码生成（uuid 字符串自渲染，官方 image.do 可省）

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
