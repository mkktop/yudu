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

  var body: some View {
    NavigationStack {
      Group {
        switch phase {
        case .qr:
          ScrollView {
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

              Text("登录凭证保存在本机钥匙串")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
        Task { await enterBrowse() }
      } else {
        startQRLogin()
      }
    }
    .onDisappear { pollTask?.cancel() }
    .interactiveDismissDisabled(busy)
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
          if try await client.pollQRLogin(login) {
            guard !Task.isCancelled else { return }
            await MainActor.run { statusText = "登录成功" }
            await enterBrowse()
            return
          }
          // 已扫码待确认的提示由状态码区分，这里统一等待文案
        } catch let error as Cloud189Client.Cloud189Error {
          if case .qrExpired = error {
            await MainActor.run { statusText = "二维码已过期，请刷新" }
            return
          }
          await MainActor.run { statusText = error.localizedDescription }
        } catch {
          continue // 网络瞬断继续轮询
        }
      }
    }
  }

  // MARK: - 浏览

  private var rootFolderId: String { "-11" }

  private func enterBrowse() async {
    busy = true
    defer { busy = false }
    families = (try? await client.familyList()) ?? []
    phase = .browse
    await load(folderId: rootFolderId)
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
