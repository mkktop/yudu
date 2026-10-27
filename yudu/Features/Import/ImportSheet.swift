import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss
  @State private var showFilePicker = false
  @State private var showFolderPicker = false
  @State private var showWebDAV = false
  @State private var showCloud189 = false
  @State private var importing = false
  @State private var outcome: ImportOutcome?

  private struct ImportOutcome {
    let message: String
    let success: Bool
  }

  private var fileTypes: [UTType] {
    [.zip, .pdf] + [UTType(filenameExtension: "cbz")].compactMap { $0 }
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          VStack(alignment: .leading, spacing: 12) {
            OrbitalEmblem(size: 54)
            SectionHeading(title: "故事，从哪里开始？", eyebrow: "ADD TO YOUR UNIVERSE")
            Text("选择一种方式，将漫画汇入你的书架。")
              .font(.subheadline).foregroundStyle(YuduTheme.muted)
          }
          VStack(alignment: .leading, spacing: 12) {
            Text("从本地添加").font(.caption.weight(.medium)).foregroundStyle(YuduTheme.muted)
            ImportEntryCard(title: "导入文件", caption: "ZIP / CBZ / PDF · 支持多选，拷贝到本机", icon: "doc.badge.plus", tint: YuduTheme.accent) { showFilePicker = true }
            ImportEntryCard(title: "授权文件夹", caption: "文件 App / iCloud · 原地读取，无需重复拷贝", icon: "folder.badge.plus", tint: YuduTheme.accent) { showFolderPicker = true }
          }
          .disabled(importing || libraryService.isScanning)
          VStack(alignment: .leading, spacing: 12) {
            Text("连接云端书库").font(.caption.weight(.medium)).foregroundStyle(YuduTheme.muted)
            ImportEntryCard(title: "WebDAV / NAS", caption: "连接坚果云或私人服务器，支持离线缓存", icon: "externaldrive.connected.to.line.below", tint: YuduTheme.violet) { showWebDAV = true }
            ImportEntryCard(title: "天翼云盘", caption: "扫码登录 · 个人云与家庭云", icon: "cloud", tint: YuduTheme.violet) { showCloud189 = true }
          }
          .disabled(importing || libraryService.isScanning)
          if importing || libraryService.isScanning {
            HStack(spacing: 12) {
              ProgressView().tint(YuduTheme.accent)
              Text(importing ? "正在导入并扫描…" : "书库正在扫描，请稍候…")
                .font(.subheadline).foregroundStyle(YuduTheme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).yuduPanel()
          }
          if let outcome {
            NoticeView(title: outcome.success ? "已添加到书架" : "未能完成添加", message: outcome.message,
                       icon: outcome.success ? "checkmark.circle" : "exclamationmark.triangle",
                       color: outcome.success ? YuduTheme.success : YuduTheme.warning)
            if outcome.success {
              Button("返回书架") { router.bookshelfPath = []; router.tab = .bookshelf; dismiss() }.buttonStyle(OrbitalButtonStyle())
            }
          }
          if !libraryService.lastErrors.isEmpty {
            NoticeView(title: "部分文件需要留意", message: libraryService.lastErrors.prefix(6).joined(separator: "\n"), icon: "exclamationmark.triangle", color: YuduTheme.warning)
          }
          Label("连接凭证保存在本机钥匙串", systemImage: "lock.shield")
            .font(.caption2).foregroundStyle(YuduTheme.muted)
        }.padding(20).frame(maxWidth: 700).frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("添加漫画")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }.disabled(importing)
        }
      }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(importing)
    .fileImporter(isPresented: $showFilePicker, allowedContentTypes: fileTypes, allowsMultipleSelection: true, onCompletion: handleFileResult)
    .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false, onCompletion: handleFolderResult)
    .sheet(isPresented: $showWebDAV) { WebDAVSetupView() }
    .sheet(isPresented: $showCloud189) { Cloud189LoginView() }
    .task {
      #if DEBUG
      let args = ProcessInfo.processInfo.arguments
      if args.contains("-yuduShowWebDAV") { showWebDAV = true }
      if args.contains("-yuduShowCloud189") { showCloud189 = true }
      #endif
    }
  }

  private func selectedURLs(_ result: Result<[URL], Error>) -> [URL] {
    switch result {
    case .success(let urls): return urls
    case .failure(let error):
      if (error as NSError).code != NSUserCancelledError {
        outcome = ImportOutcome(message: error.localizedDescription, success: false)
      }
      return []
    }
  }

  private func handleFileResult(_ result: Result<[URL], Error>) {
    let urls = selectedURLs(result)
    guard !urls.isEmpty else { return }
    let valid = urls.filter {
      let ext = MediaSniff.extensionOf($0.lastPathComponent)
      return MediaSniff.archiveExtensions.contains(ext) || MediaSniff.pdfExtensions.contains(ext)
    }
    guard !valid.isEmpty else {
      outcome = ImportOutcome(message: "请选择 ZIP、CBZ 或 PDF 文件。", success: false)
      return
    }
    importing = true
    outcome = nil
    Task {
      let result = await libraryService.importFiles(urls: valid)
      importing = false
      switch result {
      case .success(let count): outcome = ImportOutcome(message: "已导入 \(count) 个文件。", success: true)
      case .failure(let failure): outcome = ImportOutcome(message: failure.message, success: false)
      }
    }
  }

  private func handleFolderResult(_ result: Result<[URL], Error>) {
    guard let folder = selectedURLs(result).first else { return }
    importing = true
    outcome = nil
    Task {
      let result = await libraryService.addFolderLibrary(url: folder)
      importing = false
      switch result {
      case .success(let library): outcome = ImportOutcome(message: "「\(library.name)」共发现 \(library.series.count) 部漫画。", success: true)
      case .failure(let failure): outcome = ImportOutcome(message: failure.message, success: false)
      }
    }
  }
}

private struct ImportEntryCard: View {
  let title: String
  let caption: String
  let icon: String
  let tint: Color
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon).font(.system(size: 22, weight: .light))
          .foregroundStyle(tint).frame(width: 46, height: 46)
          .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        VStack(alignment: .leading, spacing: 6) {
          Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(YuduTheme.text)
          Text(caption).font(.caption).foregroundStyle(YuduTheme.muted).multilineTextAlignment(.leading)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(tint)
      }.padding(16).yuduPanel()
    }.buttonStyle(.plain)
  }
}
