import SwiftUI
import UniformTypeIdentifiers

/// 导入：文件（拷进沙盒）/ 授权文件夹（原地扫描）
struct ImportSheet: View {
  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss

  @State private var showFilePicker = false
  @State private var showFolderPicker = false
  @State private var showWebDAV = false
  @State private var showCloud189 = false
  @State private var importing = false
  @State private var resultMessage: String?

  private var fileTypes: [UTType] {
    var types: [UTType] = [.archive, .pdf]
    if let cbz = UTType(filenameExtension: "cbz") {
      types.append(cbz)
    }
    return types
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 12) {
          ImportEntryCard(
            title: "导入文件",
            caption: "zip / cbz / PDF，多选，拷贝到本机",
            icon: "doc.badge.plus",
            tint: .hex(0x4C7DD0)
          ) { showFilePicker = true }
          .disabled(importing)

          ImportEntryCard(
            title: "添加文件夹",
            caption: "“文件”App / iCloud 里的漫画文件夹，授权后原地扫描",
            icon: "folder.badge.plus",
            tint: .hex(0x3AA381)
          ) { showFolderPicker = true }
          .disabled(importing)

          ImportEntryCard(
            title: "连接 WebDAV",
            caption: "坚果云 / NAS 等网盘目录，在线阅读 + 离线缓存",
            icon: "cloud",
            tint: .hex(0x6C7BD0)
          ) { showWebDAV = true }
          .disabled(importing)

          ImportEntryCard(
            title: "天翼云盘",
            caption: "扫码登录，个人云 / 家庭云，在线阅读 + 离线缓存",
            icon: "icloud",
            tint: .cinnabar
          ) { showCloud189 = true }
          .disabled(importing)

          if importing {
            Label("正在导入并扫描…", systemImage: "arrow.down.circle")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
          }

          if let resultMessage {
            Label(resultMessage, systemImage: "checkmark.circle.fill")
              .font(.subheadline)
              .foregroundStyle(.green)
              .frame(maxWidth: .infinity)
              .padding(.vertical, 14)
              .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
          }

          if !libraryService.lastErrors.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("部分文件的问题")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
              ForEach(libraryService.lastErrors.prefix(6), id: \.self) { error in
                Text(error)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
          }

          Text("文件夹方式不占用额外空间，内容变动可在书架下拉重新扫描。")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .padding(16)
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("导入漫画")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完成") { dismiss() }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .fileImporter(
      isPresented: $showFilePicker,
      allowedContentTypes: fileTypes,
      allowsMultipleSelection: true
    ) { result in
      handleFileResult(result)
    }
    .fileImporter(
      isPresented: $showFolderPicker,
      allowedContentTypes: [.folder],
      allowsMultipleSelection: false
    ) { result in
      handleFolderResult(result)
    }
    .sheet(isPresented: $showWebDAV) {
      WebDAVSetupView()
        .environment(libraryService)
    }
    .sheet(isPresented: $showCloud189) {
      Cloud189LoginView()
        .environment(libraryService)
    }
    .task {
      #if DEBUG
      // 自测辅助：直接打开某个子流程供截图
      let args = ProcessInfo.processInfo.arguments
      if args.contains("-yuduShowWebDAV") { showWebDAV = true }
      if args.contains("-yuduShowCloud189") { showCloud189 = true }
      #endif
    }
  }

  private func handleFileResult(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, !urls.isEmpty else { return }
    let valid = urls.filter { url in
      let ext = MediaSniff.extensionOf(url.lastPathComponent)
      return MediaSniff.archiveExtensions.contains(ext) || MediaSniff.pdfExtensions.contains(ext)
    }
    guard !valid.isEmpty else {
      resultMessage = "没有可导入的文件（只支持 zip / cbz / PDF）"
      return
    }
    importing = true
    resultMessage = nil
    Task {
      let importResult = await libraryService.importFiles(urls: valid)
      importing = false
      switch importResult {
      case .success(let count):
        resultMessage = "已导入 \(count) 个文件"
      case .failure(let failure):
        resultMessage = failure.message
      }
    }
  }

  private func handleFolderResult(_ result: Result<[URL], Error>) {
    guard case .success(let urls) = result, let folder = urls.first else { return }
    importing = true
    resultMessage = nil
    Task {
      let addResult = await libraryService.addFolderLibrary(url: folder)
      importing = false
      switch addResult {
      case .success(let library):
        resultMessage = "已添加「\(library.name)」"
      case .failure(let failure):
        resultMessage = failure.message
      }
    }
  }
}

// MARK: - 导入入口卡（彩色图标砖）

private struct ImportEntryCard: View {
  let title: String
  let caption: String
  let icon: String
  let tint: Color
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: icon)
          .font(.system(size: 20, weight: .medium))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(
            LinearGradient(
              colors: [tint, tint.opacity(0.72)],
              startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12)
          )
          .shadow(color: tint.opacity(0.35), radius: 5, y: 2)

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(14)
      .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
    .buttonStyle(.plain)
  }
}
