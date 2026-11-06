import SwiftUI
import SwiftData

/// 「管理已导入资源」二级页：列出某个来源（网盘账号，或本机）下挂载的所有文件夹书库，
/// 提供扫描、移除与「导入新资源」入口。移除文件夹不动账号登录。
struct SourceManageView: View {
  /// nil = 本机书库
  let source: SourceEntity?
  @Query(sort: \LibraryEntity.createdAt) private var allLibraries: [LibraryEntity]
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService

  @State private var removingLibrary: LibraryEntity?

  private var libraries: [LibraryEntity] {
    allLibraries.filter { $0.source?.key == source?.key }
  }

  private var title: String {
    source?.name ?? "本机书库"
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 26) {
        scanProgress
        if libraries.isEmpty {
          emptyState
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(libraries) { row($0) }
          }
        }
        if !libraryService.lastErrors.isEmpty {
          NoticeView(
            title: "扫描中有 \(libraryService.lastErrors.count) 条提示",
            message: libraryService.lastErrors.prefix(5).joined(separator: "\n"),
            icon: "exclamationmark.triangle", color: YuduTheme.warning
          )
        }
        importButton
      }
      .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
    }
    .yuduPage()
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .alert(
      "移除「\(removingLibrary?.name ?? "")」？",
      isPresented: Binding(get: { removingLibrary != nil }, set: { if !$0 { removingLibrary = nil } })
    ) {
      Button("移除此文件夹", role: .destructive) {
        if let removingLibrary { libraryService.removeLibrary(removingLibrary) }
        removingLibrary = nil
      }
      Button("取消", role: .cancel) { removingLibrary = nil }
    } message: {
      Text(removingLibrary?.kind == "imports"
        ? "将删除本机导入的文件副本与阅读进度。原始文件不受影响。"
        : "将清除这个文件夹的本机记录、进度与离线缓存。账号登录与云端文件不受影响。")
    }
  }

  // MARK: - 书库行

  private func row(_ library: LibraryEntity) -> some View {
    HStack(spacing: 12) {
      Image(systemName: library.sourceIcon)
        .font(.system(size: 17, weight: .light)).foregroundStyle(YuduTheme.accent)
        .frame(width: 40, height: 40)
        .background(YuduTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
      VStack(alignment: .leading, spacing: 4) {
        Text(library.name).font(.subheadline.weight(.semibold)).lineLimit(1)
        Text("\(library.sourceLabel) · \(library.series.count) 部漫画")
          .font(.caption).foregroundStyle(YuduTheme.muted)
      }
      Spacer(minLength: 8)
      menu(library)
    }
    .padding(14).yuduPanel()
  }

  private func menu(_ library: LibraryEntity) -> some View {
    Menu {
      if let source = library.source {
        Button("在网盘中查看", systemImage: "folder") {
          router.openCloudBrowser(source: source)
        }
      }
      Picker("扫描结构", selection: Binding(
        get: { library.scanLayout },
        set: { newValue in
          Task { await libraryService.setScanLayout(newValue, for: library) }
        }
      )) {
        Text("多部漫画（子文件夹 = 各部作品）").tag(LibraryScanLayout.multi)
        Text("单部作品（整库一部，子文件夹 = 话）").tag(LibraryScanLayout.single)
      }
      .disabled(libraryService.isScanning)
      Button("增量扫描", systemImage: "bolt.horizontal.circle") {
        Task { await libraryService.rescan(library) }
      }
      .disabled(libraryService.isScanning)
      Button("完整扫描", systemImage: "arrow.triangle.2.circlepath") {
        Task { await libraryService.rescan(library, mode: .full) }
      }
      .disabled(libraryService.isScanning)
      Button(removalTitle(for: library), systemImage: "trash", role: .destructive) {
        removingLibrary = library
      }
      .disabled(libraryService.isScanning)
    } label: {
      Image(systemName: "ellipsis").frame(width: 40, height: 40)
    }
    .accessibilityLabel("管理\(library.name)")
  }

  private func removalTitle(for library: LibraryEntity) -> String {
    library.source == nil ? "移除书库" : "移除此文件夹"
  }

  // MARK: - 状态与入口

  @ViewBuilder
  private var scanProgress: some View {
    if libraryService.isScanning {
      HStack(spacing: 10) {
        ProgressView().tint(YuduTheme.accent)
        Text(libraryService.scanProgress.map { "扫描中：\($0.title)（\($0.current + 1)/\($0.total)）" } ?? "正在扫描，请稍候…")
          .font(.subheadline).foregroundStyle(YuduTheme.muted)
      }.padding(16).frame(maxWidth: .infinity, alignment: .leading).yuduPanel()
    }
  }

  private var emptyState: some View {
    NoticeView(
      title: source == nil ? "本机还没有书库" : "这个账号还没有导入文件夹",
      message: source == nil
        ? "点下方按钮导入本地漫画文件（ZIP / CBZ / PDF），或授权一个文件夹作为书库。"
        : "点下方按钮进入整盘浏览，找到漫画目录后点「导入当前文件夹为书库」。",
      icon: "folder.badge.plus"
    )
  }

  private var importButton: some View {
    Button {
      if let source {
        router.openCloudBrowser(source: source)
      } else {
        router.showImport = true
      }
    } label: {
      Label(
        source == nil ? "导入本地文件或授权文件夹" : "浏览网盘，导入新资源",
        systemImage: source == nil ? "plus" : "folder.badge.plus"
      )
    }
    .buttonStyle(OrbitalButtonStyle(prominent: false))
  }
}
