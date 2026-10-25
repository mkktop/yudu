import SwiftUI
import UniformTypeIdentifiers

/// 导入：文件（拷进沙盒）/ 授权文件夹（原地扫描）
struct ImportSheet: View {
  @Environment(LibraryService.self) private var libraryService
  @Environment(\.dismiss) private var dismiss

  @State private var showFilePicker = false
  @State private var showFolderPicker = false
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
      List {
        Section {
          Button {
            showFilePicker = true
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 3) {
                Text("导入文件")
                Text("zip / cbz / PDF，多选，拷贝到本机")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "doc.badge.plus")
            }
          }
          .disabled(importing)

          Button {
            showFolderPicker = true
          } label: {
            Label {
              VStack(alignment: .leading, spacing: 3) {
                Text("添加文件夹")
                Text("“文件”App / iCloud Drive 里的漫画文件夹，授权后原地扫描")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "folder.badge.plus")
            }
          }
          .disabled(importing)
        } footer: {
          Text("文件夹方式不占用额外空间，内容变动可在书架下拉重新扫描。")
        }

        if importing {
          Section {
            HStack(spacing: 10) {
              ProgressView()
              Text("正在导入并扫描…")
                .font(.subheadline)
            }
          }
        }

        if let resultMessage {
          Section {
            Label(resultMessage, systemImage: "checkmark.circle")
              .foregroundStyle(.green)
              .font(.subheadline)
          }
        }

        if !libraryService.lastErrors.isEmpty {
          Section("部分文件的问题") {
            ForEach(libraryService.lastErrors.prefix(6), id: \.self) { error in
              Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }
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
