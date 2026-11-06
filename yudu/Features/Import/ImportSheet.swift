import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss
  @State private var showFilePicker = false
  @State private var showFolderPicker = false
  @State private var importing = false
  @State private var outcome: ImportOutcome?
  @State private var pendingFolder: PendingFolder?

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
          Label("网盘漫画在「资源库」页添加账号后整盘浏览、随选随导", systemImage: "cloud")
            .font(.caption).foregroundStyle(YuduTheme.muted)
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
    .sheet(item: $pendingFolder) { pick in
      LibraryScanLayoutPicker(folderName: pick.url.lastPathComponent) { layout in
        pendingFolder = nil
        importFolder(pick.url, layout: layout)
      }
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
    // 有子文件夹时无法可靠区分「一部作品」还是「一个库」，先让用户选择目录结构
    let hasSubdirs: Bool = {
      let scoped = folder.startAccessingSecurityScopedResource()
      defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
      let children = (try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )) ?? []
      return children.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    }()
    if hasSubdirs {
      pendingFolder = PendingFolder(url: folder)
    } else {
      importFolder(folder, layout: .multi)
    }
  }

  private func importFolder(_ folder: URL, layout: LibraryScanLayout) {
    importing = true
    outcome = nil
    Task {
      let result = await libraryService.addFolderLibrary(url: folder, layout: layout)
      importing = false
      switch result {
      case .success(let library): outcome = ImportOutcome(message: "「\(library.name)」共发现 \(library.series.count) 部漫画。", success: true)
      case .failure(let failure): outcome = ImportOutcome(message: failure.message, success: false)
      }
    }
  }
}

/// 待确认目录结构的授权文件夹
private struct PendingFolder: Identifiable {
  let url: URL
  var id: String { url.path }
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
