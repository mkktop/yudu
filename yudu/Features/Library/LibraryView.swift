import SwiftUI
import SwiftData

/// 书库是独立的一等入口：来源管理与阅读偏好不再混在一起。
struct LibraryView: View {
  @Query(sort: \LibraryEntity.createdAt) private var libraries: [LibraryEntity]
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @State private var removing: LibraryEntity?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          SectionHeading(title: "连接你的故事", eyebrow: "LIBRARY SOURCES", detail: "\(libraries.count) 个来源")
          HStack(spacing: 12) {
            sourceMetric("本地来源", value: libraries.filter { $0.kind == "imports" || $0.kind == "folder" }.count, icon: "internaldrive")
            sourceMetric("云端来源", value: libraries.filter { $0.kind == "webdav" || $0.kind == "cloud189" }.count, icon: "cloud")
          }
          Button { router.showImport = true } label: { Label("添加书库或导入文件", systemImage: "plus") }
            .buttonStyle(OrbitalButtonStyle())
          if libraries.isEmpty {
            NoticeView(title: "你的书库，随处可达", message: "支持本地文件与文件夹，也支持 WebDAV、NAS 和天翼云盘。添加后，漫画会自动汇入书架。", icon: "square.stack.3d.up")
          } else {
            VStack(alignment: .leading, spacing: 14) {
              HStack {
                SectionHeading(title: "已添加的来源", eyebrow: "MY SOURCES")
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
              }
              ForEach(libraries) { sourceCard($0) }
            }
          }
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
          VStack(alignment: .leading, spacing: 10) {
            Label("本地与云端，一个书架", systemImage: "point.3.connected.trianglepath.dotted")
              .font(.subheadline.weight(.medium)).foregroundStyle(YuduTheme.text)
            Text("文件夹原地读取；导入文件会保留本机副本。云端漫画可在详情页离线缓存，缓存容量在设置中管理。增量扫描只复查远端有变化的目录，需要重新识别全部内容时用「完整扫描」。")
              .font(.caption).foregroundStyle(YuduTheme.muted).lineSpacing(4)
          }.padding(18).yuduPanel()
        }
        .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("书库")
      .navigationBarTitleDisplayMode(.inline)
      .confirmationDialog(
        "移除「\(removing?.name ?? "")」？",
        isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
        titleVisibility: .visible
      ) {
        Button("移除书库", role: .destructive) {
          if let removing { libraryService.removeLibrary(removing) }
          removing = nil
        }
        Button("取消", role: .cancel) { removing = nil }
      } message: {
        Text(removing?.kind == "imports"
          ? "将删除本机导入的文件副本与阅读进度。原始文件不受影响。"
          : "将清除该书库的本机记录、进度与离线缓存。原始文件和云端文件不受影响。")
      }
    }
  }

  private func sourceMetric(_ title: String, value: Int, icon: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).font(.title3).foregroundStyle(YuduTheme.accent)
      VStack(alignment: .leading, spacing: 4) {
        Text("\(value)").font(.title2.weight(.semibold).monospacedDigit())
        Text(title).font(.caption).foregroundStyle(YuduTheme.muted)
      }
      Spacer(minLength: 0)
    }.padding(18).yuduPanel()
  }

  private func sourceCard(_ library: LibraryEntity) -> some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: library.sourceIcon)
          .font(.system(size: 20, weight: .light)).foregroundStyle(YuduTheme.accent)
          .frame(width: 46, height: 46).background(YuduTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        VStack(alignment: .leading, spacing: 5) {
          Text(library.name).font(.headline).lineLimit(2)
          Text("\(library.sourceLabel) · \(library.series.count) 部漫画")
            .font(.caption).foregroundStyle(YuduTheme.muted)
        }
        Spacer(minLength: 0)
        Menu {
          Button("增量扫描", systemImage: "bolt.horizontal.circle") {
            Task { await libraryService.rescan(library) }
          }
          .disabled(libraryService.isScanning)
          Button("完整扫描", systemImage: "arrow.triangle.2.circlepath") {
            Task { await libraryService.rescan(library, mode: .full) }
          }
          .disabled(libraryService.isScanning)
          Button("移除书库", systemImage: "trash", role: .destructive) { removing = library }
            .disabled(libraryService.isScanning)
        } label: {
          Image(systemName: "ellipsis").frame(width: 44, height: 44)
        }
        .accessibilityLabel("管理\(library.name)")
      }
      HStack {
        StatusPill(text: "已添加", icon: "link")
        Spacer()
        Text(library.createdAt, format: .dateTime.year().month().day())
          .font(.caption2.monospacedDigit()).foregroundStyle(YuduTheme.muted)
      }
    }.padding(18).yuduPanel()
  }
}
