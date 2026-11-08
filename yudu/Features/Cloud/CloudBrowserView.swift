import SwiftUI

/// 网盘整盘浏览器（爆米花式）：随便逛、点开即读、顺手把文件夹导入为书库。
/// 由书库页导航栈 push 进入，标题栏始终显示当前账号与所在目录。
struct CloudBrowserView: View {
  let source: SourceEntity

  @Environment(LibraryService.self) private var libraryService
  @Environment(AppRouter.self) private var router

  @State private var provider: (any CloudBrowserProvider)?
  @State private var roots: [CloudBrowserFolder] = []
  @State private var scope: CloudBrowserFolder?
  @State private var path: [CloudBrowserItem] = []
  @State private var items: [CloudBrowserItem] = []
  @State private var busy = false
  @State private var importing = false
  @State private var message: String?
  @State private var toast: String?
  @State private var mountedKeys: Set<String> = []
  /// 当前目录里已缓存的章节 path；一次目录加载只做一遍哈希/文件检查，不在每行 body 里做。
  @State private var cachedPaths: Set<String> = []
  @State private var setupFinished = false
  /// 目录读取失败时保留目标，列表里提供原地重试。
  @State private var loadRetryFolder: CloudBrowserFolder?
  /// 目录请求代次：快速返回上一级时，避免旧请求的结果覆盖新目录。
  @State private var loadEpoch = 0
  /// 待导入的目录（单个或批量）：弹「目录结构」选择后执行
  @State private var importTarget: ImportTarget?
  /// 多选模式：勾选多个文件夹，一次导入为多个书库
  @State private var selecting = false
  @State private var selectedIDs: Set<String> = []

  private struct ImportTarget: Identifiable {
    let folders: [CloudBrowserFolder]
    let title: String
    /// 同目录内 id 唯一：首项 id + 数量即可区分不同选择，
    /// 避免全部 id 拼接的超长 key 与 "a|b"+"c" == "a"+"b|c" 的歧义
    var id: String { "\(folders.count)@\(folders.first?.id ?? "")" }
  }

  private var isCloud189: Bool { source.kind == "cloud189" }

  /// 当前所在目录（含天翼空间归属）；provider 未就绪时为 nil
  private var currentFolder: CloudBrowserFolder? {
    guard provider != nil else { return nil }
    if let last = path.last {
      return CloudBrowserFolder(id: last.id, name: last.name, familyId: scope?.familyId)
    }
    return scope
  }

  private var displayName: String {
    if let last = path.last { return last.name }
    let scopeName = scope?.name ?? ""
    return scopeName.isEmpty ? source.name : scopeName
  }

  private var directoryItems: [CloudBrowserItem] {
    items.filter(\.isDirectory)
  }

  /// 勾选中的文件夹（与当前目录 items 对齐）
  private var selectedFolders: [CloudBrowserFolder] {
    directoryItems
      .filter { selectedIDs.contains($0.id) }
      .map { CloudBrowserFolder(id: $0.id, name: $0.name, familyId: scope?.familyId) }
  }

  private func isMounted(_ folder: CloudBrowserFolder) -> Bool {
    mountedKeys.contains(provider?.mountKey(for: folder) ?? "")
  }

  var body: some View {
    List {
      if isCloud189, roots.count > 1 {
        Section { scopePicker }
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 0, trailing: 20))
      }
      Section {
        if !path.isEmpty {
          Button { goUp() } label: {
            Label("上一级", systemImage: "arrow.up")
          }
        }
        if let folder = loadRetryFolder {
          Button {
            loadRetryFolder = nil
            Task { await load(folder) }
          } label: {
            Label("重新加载此目录", systemImage: "arrow.clockwise")
          }
        }
        if !busy && items.isEmpty && message == nil {
          Text("此目录为空。找有漫画的文件夹，点底部按钮导入为书库。")
            .font(.subheadline).foregroundStyle(YuduTheme.muted)
        }
        ForEach(items.filter(\.isDirectory)) { item in
          folderRow(item)
        }
        ForEach(items.filter { $0.isReadable }) { item in
          fileRow(item)
        }
      } footer: {
        let loose = items.filter(\.isReadable).count
        if loose > 0 {
          Text("此处有 \(loose) 个压缩包 / PDF，点开可直接在线试读；导入当前文件夹后可进书架长期阅读。")
        }
      }
    }
    .disabled(busy || provider == nil)
    .yuduPage()
    .navigationTitle(path.last?.name ?? source.name)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(!path.isEmpty)
    .toolbar {
      if !path.isEmpty {
        ToolbarItem(placement: .topBarLeading) {
          Button { goUp() } label: {
            Label("上一级", systemImage: "chevron.left")
          }
        }
      }
      if selecting {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            toggleSelectAll()
          } label: {
            Text(directoryItems.allSatisfy { selectedIDs.contains($0.id) } ? "取消全选" : "全选")
          }
        }
      }
      if !directoryItems.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            selecting.toggle()
            if !selecting { selectedIDs = [] }
          } label: {
            Text(selecting ? "完成" : "选择")
          }
          .accessibilityLabel(selecting ? "退出选择模式" : "批量选择文件夹")
        }
      }
    }
    .overlay {
      if busy {
        ProgressView()
      } else if setupFinished, provider == nil {
        VStack(spacing: 14) {
          Image(systemName: "exclamationmark.triangle")
            .font(.largeTitle)
            .foregroundStyle(.white.opacity(0.65))
          Text("无法打开这个网盘").font(.headline)
          Text("检查网络或账号状态后重试。")
            .font(.caption).foregroundStyle(YuduTheme.muted)
          Button("重试") { Task { await setup() } }
            .buttonStyle(.borderedProminent)
            .tint(YuduTheme.accent)
        }
        .padding(24)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
      }
    }
    .overlay(alignment: .top) {
      if let text = toast {
        Label(text, systemImage: "checkmark.circle.fill")
          .font(.footnote.weight(.medium))
          .foregroundStyle(YuduTheme.text)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(Capsule().fill(YuduTheme.surface).shadow(color: .black.opacity(0.25), radius: 12, y: 4))
          .padding(.top, 6)
          .task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation { self.toast = nil }
          }
          .transition(.opacity)
      }
    }
    .safeAreaInset(edge: .bottom) { importBar }
    .sheet(item: $importTarget) { target in
      LibraryScanLayoutPicker(folderName: target.title) { layout in
        importTarget = nil
        Task { await performImport(target.folders, title: target.title, layout: layout) }
      }
    }
    .onAppear { refreshCachedSet() }
    .alert("无法完成操作", isPresented: Binding(
      get: { message != nil },
      set: { if !$0 { message = nil } }
    )) {
      Button("好") { message = nil }
    } message: {
      Text(message ?? "")
    }
    .task { await setup() }
  }

  // MARK: - 行

  @ViewBuilder
  private func folderRow(_ item: CloudBrowserItem) -> some View {
    let folder = CloudBrowserFolder(id: item.id, name: item.name, familyId: scope?.familyId)
    let mounted = isMounted(folder)
    let selected = selectedIDs.contains(item.id)
    let row = Button {
      if selecting {
        if selected {
          selectedIDs.remove(item.id)
        } else {
          selectedIDs.insert(item.id)
        }
      } else {
        path.append(item)
        if let folder = currentFolder { Task { await load(folder) } }
      }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "folder.fill")
          .foregroundStyle(YuduTheme.accent)
        Text(item.name).foregroundStyle(.primary).lineLimit(1)
        Spacer()
        if mounted {
          StatusPill(text: "已导入", color: YuduTheme.success, icon: "checkmark.seal.fill")
        }
        if selecting {
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.body.weight(.medium))
            .foregroundStyle(selected ? YuduTheme.accent : YuduTheme.muted)
        } else {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
      }
    }
    .accessibilityLabel(selecting
      ? "\(item.name)，\(selected ? "已选中" : "未选中")"
      : "打开文件夹 \(item.name)")
    // 选择模式屏蔽长按菜单，避免误触「试读」打断批量操作
    if selecting {
      row
    } else {
      row.contextMenu {
        Button {
          importTarget = ImportTarget(folders: [folder], title: item.name)
        } label: {
          Label("导入此文件夹为书库", systemImage: "plus.square.on.square")
        }
        Button {
          previewRead(item)
        } label: {
          Label("在线试读此文件夹", systemImage: "book")
        }
      }
    }
  }

  private func fileRow(_ item: CloudBrowserItem) -> some View {
    let cached = cachePath(for: item).map { cachedPaths.contains($0) } ?? false
    return Button {
      previewRead(item)
    } label: {
      HStack(spacing: 12) {
        Image(systemName: item.isPDF ? "doc.richtext" : "doc.zipper")
          .foregroundStyle(YuduTheme.violet)
          .frame(width: 28)
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name).foregroundStyle(.primary).lineLimit(1)
          Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            .font(.caption2.monospacedDigit()).foregroundStyle(YuduTheme.muted)
        }
        Spacer()
        if cached {
          StatusPill(text: "已缓存", color: YuduTheme.accent, icon: "internaldrive.fill")
        }
        Image(systemName: "book")
          .font(.caption).foregroundStyle(YuduTheme.accent)
      }
    }
    // 文件不能挂载为书库，选择模式下不可点，避免误触试读
    .disabled(selecting)
    .opacity(selecting ? 0.45 : 1)
  }

  private var scopePicker: some View {
    Picker("空间", selection: Binding(
      get: { scope },
      set: { newValue in
        scope = newValue
        path = []
        if let folder = newValue { Task { await load(folder) } }
      }
    )) {
      // 天翼各空间的根 id 都是 "-11"，只靠 familyId 区分——不能用 id: \.id（会全部同身份）
      ForEach(roots, id: \.self) { root in
        Text(root.name).tag(CloudBrowserFolder?.some(root))
      }
    }
    .pickerStyle(.segmented)
  }

  private var importBar: some View {
    let selected = selectedFolders
    let pending = selected.filter { !isMounted($0) }
    let currentMounted = currentFolder.map { isMounted($0) } ?? false
    let allSelectedMounted = !selected.isEmpty && pending.isEmpty
    let icon: String
    let label: String
    if selecting {
      if selected.isEmpty {
        icon = "plus.square.on.square"
        label = "勾选要导入的文件夹"
      } else if allSelectedMounted {
        icon = "checkmark.seal.fill"
        label = "所选文件夹已导入"
      } else {
        // 计数按待导入（跳过已导入）的算，与实际执行一致
        icon = "plus.square.on.square"
        label = pending.count < selected.count
          ? "导入 \(pending.count) 个文件夹（跳过已导入）"
          : "导入 \(pending.count) 个文件夹为书库"
      }
    } else {
      icon = currentMounted ? "checkmark.seal.fill" : "plus.square.on.square"
      label = currentMounted ? "已导入为书库" : "导入当前文件夹为书库"
    }
    let disabled = importing || busy || provider == nil
      || (selecting ? selected.isEmpty || allSelectedMounted : currentMounted)
    return Button {
      guard let folder = currentFolder else { return }
      if selecting, !selected.isEmpty {
        // 目录结构选择一次应用到整批
        importTarget = ImportTarget(folders: selected, title: "\(selected.count) 个文件夹")
      } else if items.contains(where: \.isDirectory) {
        // 目录里有子文件夹时无法可靠区分「一部作品」还是「一个库」，交给用户选择
        importTarget = ImportTarget(folders: [folder], title: displayName)
      } else {
        Task { await performImport([folder], title: displayName, layout: .multi) }
      }
    } label: {
      HStack(spacing: 8) {
        if importing { ProgressView().tint(YuduTheme.background) }
        Image(systemName: icon)
        Text(label)
          .font(.subheadline.weight(.semibold))
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(OrbitalButtonStyle())
    .disabled(disabled)
    .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
    .background {
      Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
        .overlay(alignment: .top) {
          Rectangle().fill(YuduTheme.line).frame(height: 0.5)
        }
    }
  }

  // MARK: - 状态

  /// 返回上一级目录（系统返回键在子目录里也执行这个语义，而不是直接退出浏览器）。
  private func goUp() {
    guard !path.isEmpty else { return }
    path.removeLast()
    if let folder = currentFolder { Task { await load(folder) } }
  }

  private func toggleSelectAll() {
    let ids = directoryItems.map(\.id)
    if ids.allSatisfy({ selectedIDs.contains($0) }) {
      selectedIDs.subtract(ids)
    } else {
      selectedIDs.formUnion(ids)
    }
  }

  private func setup() async {
    guard provider == nil else { return }
    busy = true
    setupFinished = false
    message = nil
    defer {
      busy = false
      setupFinished = true
    }
    switch source.kind {
    case "webdav":
      guard let client = libraryService.webdavClient(for: source),
            let root = source.baseURL.flatMap({ URL(string: $0) }) else {
        message = "账号配置无效，请删除账号后重新添加"
        return
      }
      let p = WebDAVBrowserProvider(client: client, rootURL: root)
      provider = p
      let found = await p.roots()
      roots = found
      scope = found.first
    case "cloud189":
      let client = libraryService.cloud189Client(for: source)
      guard client.isLoggedIn else {
        message = "登录已失效，请回到资源库页，在该账号卡片菜单中选择「重新登录」"
        return
      }
      let p = Cloud189BrowserProvider(client: client)
      provider = p
      let found = await p.roots()
      roots = found
      scope = found.first
    default:
      break
    }
    refreshMounted()
    if let folder = currentFolder {
      await load(folder)
    }
  }

  private func load(_ folder: CloudBrowserFolder) async {
    guard let provider else { return }
    loadEpoch += 1
    let epoch = loadEpoch
    busy = true
    defer {
      // 只有最新一次请求能结束 loading 状态。
      if epoch == loadEpoch { busy = false }
    }
    items = []
    cachedPaths = []
    loadRetryFolder = nil
    selectedIDs = []
    selecting = false
    do {
      let listed = try await provider.list(folder)
      guard epoch == loadEpoch, !Task.isCancelled else { return }
      items = listed
      refreshCachedSet()
    } catch {
      guard epoch == loadEpoch else { return }
      message = error.localizedDescription
      loadRetryFolder = folder
    }
  }

  private func refreshMounted() {
    mountedKeys = libraryService.mountedLibraryKeys()
  }

  // MARK: - 导入 / 试读

  /// 挂载一个或多个文件夹为书库；已导入的自动跳过，每个书库的首次扫描排队后台执行
  private func performImport(
    _ folders: [CloudBrowserFolder], title: String, layout: LibraryScanLayout
  ) async {
    guard provider != nil else { return }
    importing = true
    defer { importing = false }

    let pending = folders.filter { !isMounted($0) }
    guard !pending.isEmpty else {
      message = "所选文件夹都已导入过"
      return
    }

    var ok = 0
    var lastName: String?
    var failures: [String] = []

    switch source.kind {
    case "webdav":
      guard let client = libraryService.webdavClient(for: source) else {
        message = "WebDAV 账号配置无效"
        return
      }
      // 批量只在开头验证一次连接，逐个挂载时跳过 verify
      do {
        try await client.verify()
      } catch {
        message = error.localizedDescription
        return
      }
      for folder in pending {
        guard let url = URL(string: folder.id) else {
          failures.append("\(folder.name)：目录地址无效")
          continue
        }
        let result = await libraryService.addWebDAVLibrary(
          source: source, folderURL: url, layout: layout, verifyConnection: false
        )
        switch result {
        case .success(let library): ok += 1; lastName = library.name
        case .failure(let failure): failures.append("\(folder.name)：\(failure.message)")
        }
      }
    case "cloud189":
      guard libraryService.cloud189Client(for: source).isLoggedIn else {
        message = "天翼云盘未登录，请回资源库页重新登录"
        return
      }
      for folder in pending {
        let result = await libraryService.addCloud189Library(
          source: source, folderId: folder.id, familyId: folder.familyId,
          name: folder.name.isEmpty ? title : folder.name, layout: layout
        )
        switch result {
        case .success(let library): ok += 1; lastName = library.name
        case .failure(let failure): failures.append("\(folder.name)：\(failure.message)")
        }
      }
    default:
      return
    }

    refreshMounted()
    if ok > 0 {
      let text: String
      if pending.count == 1, let lastName {
        text = "已导入「\(lastName)」，正在后台扫描"
      } else {
        text = "已导入 \(ok) 个文件夹，正在后台扫描"
          + (failures.isEmpty ? "" : "，\(failures.count) 个失败")
      }
      withAnimation { toast = text }
    }
    if !failures.isEmpty {
      message = failures.prefix(5).joined(separator: "\n")
    }
    selecting = false
    selectedIDs = []
  }

  /// 点开即读：同目录内可连读；散图文件夹整目录作为一章
  private func previewRead(_ item: CloudBrowserItem) {
    guard let provider, let folder = currentFolder else { return }
    let list: [CloudBrowserItem]
    let index: Int
    if item.isDirectory {
      list = [item]
      index = 0
    } else {
      let files = items.filter(\.isReadable)
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      guard let i = files.firstIndex(where: { $0.id == item.id }) else { return }
      list = files
      index = i
    }
    let payload = PreviewPayload(
      sourceKey: source.key,
      sourceKind: source.kind,
      folderTitle: path.last?.name ?? displayName,
      items: list.map { entry in
        PreviewChapterItem(
          path: provider.chapterPath(for: entry, folder: folder),
          kind: provider.chapterKind(for: entry),
          title: MediaSniff.stemOf(entry.name),
          size: entry.size,
          modifiedAt: entry.modifiedAt ?? .distantPast
        )
      },
      index: index
    )
    router.openPreviewReader(payload)
  }

  private func cachePath(for item: CloudBrowserItem) -> String? {
    guard let provider, let folder = currentFolder, item.isReadable else { return nil }
    return provider.chapterPath(for: item, folder: folder)
  }

  /// 目录加载后一次性算出“已缓存”集合；之前每个文件行 body 都要做一次 SHA256 + 文件检查。
  private func refreshCachedSet() {
    guard let provider, let folder = currentFolder else {
      cachedPaths = []
      return
    }
    var result: Set<String> = []
    for item in items where item.isReadable {
      let path = provider.chapterPath(for: item, folder: folder)
      if let url = URL(string: path), WebDAVCache.shared.chapterCacheURL(for: url) != nil {
        result.insert(path)
      }
    }
    cachedPaths = result
  }
}
