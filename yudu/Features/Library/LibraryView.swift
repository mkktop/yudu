import SwiftUI
import SwiftData

/// 「…」操作面板的载荷：source 为 nil 表示本机书库
private struct SourceActionsTarget: Identifiable {
  let source: SourceEntity?
  var id: String { source?.key ?? "local" }
}

/// 资源库页（爆米花式来源管理）：主页只放来源卡片——本机 + 各网盘账号（按供应商分组），
/// 点「…」弹出底部操作面板：管理已导入资源 / 导入新资源 / 删除文件源；
/// 已导入的文件夹收进「管理已导入资源」二级页。移除文件夹不动账号，移除账号才级联。
struct LibraryView: View {
  @Query(sort: \SourceEntity.createdAt) private var sources: [SourceEntity]
  @Query(sort: \LibraryEntity.createdAt) private var libraries: [LibraryEntity]
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService

  @State private var showAddSheet = false
  @State private var editingSource: SourceEntity?
  @State private var removingSource: SourceEntity?
  @State private var actionsTarget: SourceActionsTarget?
  @State private var statusVersion = 0
  @State private var accountStatus: [String: AccountStatus] = [:]

  private enum AccountStatus { case checking, connected, needsRelogin }

  private var localLibraries: [LibraryEntity] {
    libraries.filter { $0.source == nil }
  }

  private var cloud189Sources: [SourceEntity] {
    sources.filter { $0.kind == "cloud189" }
  }

  private var webdavSources: [SourceEntity] {
    sources.filter { $0.kind == "webdav" }
  }

  var body: some View {
    @Bindable var router = router
    NavigationStack(path: $router.libraryPath) {
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          heading
          localSection
          providerSection(title: "天翼云盘", eyebrow: "CLOUD189", group: cloud189Sources)
          providerSection(title: "WebDAV / NAS", eyebrow: "WEBDAV", group: webdavSources)
          if sources.isEmpty { emptyClouds }
          scanStatus
          helpPanel
        }
        .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("资源库")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItemGroup(placement: .topBarTrailing) {
          Menu {
            Button("增量扫描", systemImage: "bolt.horizontal.circle") {
              Task { await libraryService.rescanAll() }
            }
            Button("完整扫描（较慢）", systemImage: "arrow.triangle.2.circlepath") {
              Task { await libraryService.rescanAll(mode: .full) }
            }
          } label: {
            Image(systemName: "arrow.triangle.2.circlepath").frame(width: 44, height: 44)
          }
          .disabled(libraryService.isScanning)
          .accessibilityLabel("扫描全部书库")
          Button { router.showImport = true } label: {
            Image(systemName: "arrow.down.to.line").frame(width: 44, height: 44)
          }
          .accessibilityLabel("导入本地文件或授权文件夹")
          Button { showAddSheet = true } label: {
            Image(systemName: "plus").frame(width: 44, height: 44)
          }
          .accessibilityLabel("添加网盘账号")
        }
      }
      .navigationDestination(for: LibraryRoute.self) { route in
        destination(route)
      }
    }
    .sheet(isPresented: $showAddSheet) {
      AddSourceSheet { source in
        router.openCloudBrowser(source: source)
        statusVersion += 1
      }
    }
    .sheet(item: $editingSource) { source in
      AddSourceSheet(existing: source) { _ in
        statusVersion += 1
      }
    }
    .sheet(item: $actionsTarget) { target in
      sourceActionsSheet(target)
    }
    .alert(
      "移除账号「\(removingSource?.name ?? "")」？",
      isPresented: Binding(get: { removingSource != nil }, set: { if !$0 { removingSource = nil } })
    ) {
      Button("移除账号及其文件夹", role: .destructive) {
        if let source = removingSource {
          libraryService.removeSource(source)
          router.libraryPath.removeAll()
        }
        removingSource = nil
      }
      Button("取消", role: .cancel) { removingSource = nil }
    } message: {
      let count = libraries.filter { $0.source?.key == removingSource?.key }.count
      Text(count > 0
        ? "它下面导入的 \(count) 个文件夹书库会一并移除，本机的阅读进度与离线缓存同时清除。云端文件不受影响。"
        : "账号登录信息将被清除。云端文件不受影响。")
    }
    .task(id: statusVersion) {
      await refreshAccountStatus()
    }
  }

  // MARK: - 「…」操作面板（自定义底部面板：iOS 26 confirmationDialog 渲染位置不稳）

  private func sourceActionsSheet(_ target: SourceActionsTarget) -> some View {
    VStack(spacing: 14) {
      Text(target.source?.name ?? "本地书库")
        .font(.caption.weight(.semibold))
        .foregroundStyle(YuduTheme.muted)
        .padding(.top, 6)
      VStack(spacing: 10) {
        actionRow("管理已导入资源") {
          actionsTarget = nil
          router.openSourceManage(source: target.source)
        }
        actionRow(target.source == nil ? "导入本地文件" : "导入新资源") {
          actionsTarget = nil
          guard let source = target.source else {
            // 等本面板收起后再呈现导入面板，避免两个 sheet 同帧争抢
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(0.45))
              router.showImport = true
            }
            return
          }
          router.openCloudBrowser(source: source)
        }
        if let source = target.source {
          actionRow(source.kind == "cloud189" ? "重新登录" : "编辑账号") {
            actionsTarget = nil
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(0.45))
              editingSource = source
            }
          }
          actionRow("删除文件源", destructive: true) {
            actionsTarget = nil
            // 等面板收起后再弹确认，避免同帧争抢呈现
            Task { @MainActor in
              try? await Task.sleep(for: .seconds(0.45))
              removingSource = source
            }
          }
        }
      }
      actionRow("取消", tint: YuduTheme.text) {
        actionsTarget = nil
      }
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .presentationDetents([.height(target.source == nil ? 240 : 365)])
    .presentationDragIndicator(.visible)
    .presentationBackground(YuduTheme.surface)
  }

  private func actionRow(
    _ title: String,
    destructive: Bool = false,
    tint: Color = YuduTheme.accent,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(destructive ? Color.red : tint)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(YuduTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
  }

  // MARK: - 大标题

  private var heading: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("RESOURCE HUB")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .tracking(2.5).foregroundStyle(YuduTheme.accent)
      Text("资源库")
        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
        .minimumScaleFactor(0.7)
      Text("管理文件来源：本机与网盘账号。")
        .font(.subheadline).foregroundStyle(YuduTheme.muted)
    }
    .accessibilityElement(children: .combine)
  }

  // MARK: - 本机

  private var localSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeading(
        title: "本机",
        eyebrow: "ON DEVICE",
        detail: localLibraries.isEmpty ? "" : "\(localLibraries.count) 个书库"
      )
      HStack(spacing: 12) {
        Button {
          router.openSourceManage(source: nil)
        } label: {
          HStack(spacing: 14) {
            Image(systemName: "internaldrive")
              .font(.system(size: 20, weight: .light)).foregroundStyle(YuduTheme.violet)
              .frame(width: 46, height: 46)
              .background(YuduTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
              Text("本地书库").font(.headline).lineLimit(1)
              Text(localSubtitle).font(.caption).foregroundStyle(YuduTheme.muted).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
          }
        }
        .buttonStyle(.plain)
        Button {
          actionsTarget = SourceActionsTarget(source: nil)
        } label: {
          Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("管理本地书库")
      }
      .padding(16).yuduPanel()
    }
  }

  private var localSubtitle: String {
    if localLibraries.isEmpty { return "导入文件或授权文件夹开始" }
    let series = localLibraries.reduce(0) { $0 + $1.series.count }
    return series > 0 ? "\(localLibraries.count) 个书库 · \(series) 部漫画" : "\(localLibraries.count) 个书库"
  }

  // MARK: - 网盘账号

  @ViewBuilder
  private func providerSection(title: String, eyebrow: String, group: [SourceEntity]) -> some View {
    if !group.isEmpty {
      VStack(alignment: .leading, spacing: 14) {
        SectionHeading(
          title: title,
          eyebrow: eyebrow,
          detail: group.count > 1 ? "\(group.count) 个账号" : ""
        )
        ForEach(group) { accountCard($0) }
      }
    }
  }

  private func accountCard(_ source: SourceEntity) -> some View {
    HStack(spacing: 12) {
      Button {
        router.openCloudBrowser(source: source)
      } label: {
        HStack(spacing: 14) {
          Image(systemName: source.sourceIcon)
            .font(.system(size: 20, weight: .light)).foregroundStyle(YuduTheme.violet)
            .frame(width: 46, height: 46)
            .background(YuduTheme.violet.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
          VStack(alignment: .leading, spacing: 5) {
            Text(source.name).font(.headline).lineLimit(1)
            Text(accountSubtitle(source)).font(.caption).foregroundStyle(YuduTheme.muted).lineLimit(1)
          }
          Spacer(minLength: 8)
          statusPill(source)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
      }
      .buttonStyle(.plain)
      Button {
        actionsTarget = SourceActionsTarget(source: source)
      } label: {
        Image(systemName: "ellipsis").frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("管理账号\(source.name)")
    }
    .padding(16).yuduPanel()
  }

  private var emptyClouds: some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeading(title: "网盘", eyebrow: "CLOUD DRIVES")
      NoticeView(
        title: "先添加一个网盘账号",
        message: "支持 WebDAV / NAS 和天翼云盘。登录一次即可整盘浏览，想把哪个文件夹收进书架都由你决定；同一种网盘也可以添加多个账号。",
        icon: "cloud"
      )
      Button { showAddSheet = true } label: {
        HStack(spacing: 14) {
          Image(systemName: "plus")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(YuduTheme.accent)
            .frame(width: 46, height: 46)
            .background(YuduTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
          VStack(alignment: .leading, spacing: 4) {
            Text("添加网盘账号").font(.subheadline.weight(.semibold)).foregroundStyle(YuduTheme.text)
            Text("WebDAV / NAS · 天翼云盘，可添加多个").font(.caption).foregroundStyle(YuduTheme.muted)
          }
          Spacer()
        }
        .padding(16)
        .yuduPanel()
        .overlay {
          RoundedRectangle(cornerRadius: 22).strokeBorder(YuduTheme.line, style: StrokeStyle(lineWidth: 1, dash: [5]))
        }
      }
      .buttonStyle(.plain)
    }
  }

  private func accountSubtitle(_ source: SourceEntity) -> String {
    let folderCount = libraries.filter { $0.source?.key == source.key }.count
    let folderText = folderCount > 0 ? " · 已导入 \(folderCount) 个文件夹" : ""
    switch source.kind {
    case "webdav":
      let host = source.baseURL.flatMap { URL(string: $0)?.host } ?? "WebDAV"
      let user = source.username ?? ""
      return user.isEmpty ? host + folderText : "\(user)@\(host)\(folderText)"
    case "cloud189":
      return (source.username ?? "天翼云盘") + folderText
    default:
      return source.name
    }
  }

  @ViewBuilder
  private func statusPill(_ source: SourceEntity) -> some View {
    switch accountStatus[source.key] ?? .checking {
    case .checking:
      StatusPill(text: "检查中", color: YuduTheme.muted, icon: "ellipsis")
    case .connected:
      StatusPill(text: "已连接", color: YuduTheme.success, icon: "link")
    case .needsRelogin:
      StatusPill(text: "需重新登录", color: YuduTheme.warning, icon: "exclamationmark.triangle")
    }
  }

  private func refreshAccountStatus() async {
    for source in sources {
      switch source.kind {
      case "webdav":
        accountStatus[source.key] = .checking
        guard let client = libraryService.webdavClient(for: source) else {
          accountStatus[source.key] = .needsRelogin
          continue
        }
        do {
          try await client.verify()
          accountStatus[source.key] = .connected
        } catch {
          accountStatus[source.key] = .needsRelogin
        }
      case "cloud189":
        let session = libraryService.cloud189Client(for: source).session
        accountStatus[source.key] = (session?.expiresAt ?? .distantPast) > .now ? .connected : .needsRelogin
      default:
        break
      }
    }
  }

  // MARK: - 扫描状态

  @ViewBuilder
  private var scanStatus: some View {
    if libraryService.isScanning {
      HStack(spacing: 10) {
        ProgressView().tint(YuduTheme.accent)
        Text(libraryService.scanProgress.map { "扫描中：\($0.title)（\($0.current + 1)/\($0.total)）" } ?? "正在扫描，请稍候…")
          .font(.subheadline).foregroundStyle(YuduTheme.muted)
      }.padding(16).frame(maxWidth: .infinity, alignment: .leading).yuduPanel()
    } else if let summary = libraryService.lastScanSummary {
      Label(summary, systemImage: "checkmark.circle")
        .font(.caption).foregroundStyle(YuduTheme.muted)
        .padding(.horizontal, 2)
    }
    if !libraryService.lastErrors.isEmpty {
      NoticeView(title: "扫描中有 \(libraryService.lastErrors.count) 条提示", message: libraryService.lastErrors.prefix(5).joined(separator: "\n"), icon: "exclamationmark.triangle", color: YuduTheme.warning)
    }
  }

  // MARK: - 帮助

  private var helpPanel: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("账号管登录，文件夹管书架", systemImage: "point.3.connected.trianglepath.dotted")
        .font(.subheadline.weight(.medium)).foregroundStyle(YuduTheme.text)
      Text("点账号卡片逛网盘，点「…」管理来源：导入新资源、查看已导入的文件夹，或删除账号。移除文件夹不影响账号登录；云端漫画在详情页可离线缓存。")
        .font(.caption).foregroundStyle(YuduTheme.muted).lineSpacing(4)
    }.padding(18).yuduPanel()
  }

  // MARK: - 导航目的地

  @ViewBuilder
  private func destination(_ route: LibraryRoute) -> some View {
    switch route {
    case .browser(let source):
      CloudBrowserView(source: source)
    case .sourceManage(let source):
      SourceManageView(source: source)
    case .previewReader(let payload, let token):
      let webdav = payload.sourceKind == "webdav" ? libraryService.webdavClient(sourceKey: payload.sourceKey) : nil
      let cloud189 = payload.sourceKind == "cloud189" ? libraryService.cloud189Client(sourceKey: payload.sourceKey) : nil
      ReaderView(
        series: nil, startChapter: nil, preview: ReaderView.PreviewInput(
          chapters: payload.items.map { item in
            ChapterRef(
              id: item.path, path: item.path, title: item.title, kind: item.kind,
              pageCount: 0, seriesKey: "preview:" + item.path, seriesTitle: payload.folderTitle,
              modifiedAt: item.modifiedAt, fileSize: item.size
            )
          },
          index: payload.index, webdavClient: webdav, cloud189Client: cloud189
        ),
        token: token
      )
    }
  }
}
