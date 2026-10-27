import SwiftUI
import SwiftData

struct SeriesDetailView: View {
  let series: SeriesEntity
  @Environment(\.modelContext) private var context
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @State private var collapsedVolumes: Set<String> = []
  @State private var showResetConfirm = false
  @State private var showDeleteConfirm = false
  @State private var unreadOnly = false
  @State private var reverseOrder = false
  @State private var refreshTick = 0

  private struct VolumeGroup: Identifiable {
    var id: String { volume ?? "…" }
    var volume: String?
    var chapters: [ChapterEntity]
  }
  private var orderedChapters: [ChapterEntity] { Queries.orderedChapters(series) }
  private var groups: [VolumeGroup] {
    let visible = orderedChapters.filter { !unreadOnly || $0.progress?.completed != true }
    let chapters = reverseOrder ? Array(visible.reversed()) : visible
    var result: [VolumeGroup] = []
    for chapter in chapters {
      if result.last?.volume == chapter.volume, !result.isEmpty {
        result[result.count - 1].chapters.append(chapter)
      } else { result.append(VolumeGroup(volume: chapter.volume, chapters: [chapter])) }
    }
    return result
  }

  var body: some View {
    let _ = refreshTick
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          hero
          HStack {
            SectionHeading(title: "章节目录", eyebrow: "CHAPTER INDEX", detail: "\(orderedChapters.count) 话")
            Button { reverseOrder.toggle() } label: {
              Image(systemName: "arrow.up.arrow.down").frame(width: 44, height: 44)
            }
            .accessibilityLabel(reverseOrder ? "切换为正序" : "切换为倒序")
          }
          HStack(spacing: 12) {
            Toggle("只看未读", isOn: $unreadOnly).font(.caption).toggleStyle(.switch)
            Spacer(minLength: 10)
            if let target = Queries.continueTarget(series) {
              Button("定位续读") {
                unreadOnly = false
                collapsedVolumes.remove(target.volume ?? "…")
                // 等待分组展开后再定位，避免对尚未插入的行滚动。
                Task { @MainActor in
                  await Task.yield()
                  withAnimation { proxy.scrollTo(target.persistentModelID, anchor: .center) }
                }
              }.font(.caption).fixedSize().frame(minHeight: 44)
            }
          }
          if groups.isEmpty {
            NoticeView(title: orderedChapters.isEmpty ? "还没有可读章节" : "所有章节都已读完", message: orderedChapters.isEmpty ? "返回书架下拉刷新，或到书库检查来源。" : "关闭「只看未读」可以重新阅读。", icon: "book.closed")
          }
          ForEach(groups) { group in
            VStack(spacing: 0) {
              Button {
                if collapsedVolumes.contains(group.id) { collapsedVolumes.remove(group.id) }
                else { collapsedVolumes.insert(group.id) }
              } label: {
                HStack(spacing: 10) {
                  Image(systemName: "square.stack").foregroundStyle(YuduTheme.accent)
                  Text(group.volume.map { "第 \($0) 卷" } ?? "全部章节")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(YuduTheme.text)
                  Spacer()
                  Text("\(group.chapters.count) 话").font(.caption).foregroundStyle(YuduTheme.muted)
                  Image(systemName: collapsedVolumes.contains(group.id) ? "chevron.down" : "chevron.up")
                    .font(.caption2).foregroundStyle(YuduTheme.muted)
                }.padding(16).frame(minHeight: 52).contentShape(Rectangle())
              }.buttonStyle(.plain)
              if !collapsedVolumes.contains(group.id) {
                ForEach(group.chapters) { chapter in
                  Divider().overlay(YuduTheme.line).padding(.horizontal, 16)
                  chapterRow(chapter).id(chapter.persistentModelID)
                }
              }
            }.yuduPanel()
          }
        }
        .padding(20).padding(.bottom, 16).frame(maxWidth: 800).frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("作品详情")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("全部标记已读", systemImage: "checkmark.circle") {
              Queries.markAllRead(series, context: context); refreshTick += 1
            }
            Button("重置阅读进度", systemImage: "arrow.counterclockwise", role: .destructive) { showResetConfirm = true }
            if series.library?.kind == "imports" {
              Button("删除导入的漫画", systemImage: "trash", role: .destructive) { showDeleteConfirm = true }
            }
          } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
          .accessibilityLabel("管理漫画与阅读进度")
        }
      }
      .confirmationDialog("重置阅读进度？", isPresented: $showResetConfirm, titleVisibility: .visible) {
        Button("重置", role: .destructive) { Queries.resetProgress(series, context: context); refreshTick += 1 }
        Button("取消", role: .cancel) {}
      } message: { Text("清空本书所有章节的进度，文件与阅读统计会保留。") }
      .confirmationDialog("删除该漫画？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
        Button("删除", role: .destructive) {
          libraryService.removeImportedSeries(series)
          if !router.bookshelfPath.isEmpty { router.bookshelfPath.removeLast() }
        }
        Button("取消", role: .cancel) {}
      } message: { Text("将删除导入时拷贝的文件与全部进度。") }
    }
  }

  private var hero: some View {
    let info = Queries.info(series)
    return VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 18) {
        CoverImage(seriesKey: series.key, title: series.title)
          .frame(width: 108, height: 148).clipShape(RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 12) {
          StatusPill(text: info.status.label, color: info.status.color)
          Text(series.title).font(.title2.weight(.semibold)).lineLimit(4)
          Label(series.library?.sourceLabel ?? "本机文件", systemImage: series.library?.sourceIcon ?? "internaldrive")
            .font(.caption).foregroundStyle(YuduTheme.muted)
          Text("已读 \(info.read) / \(info.total) 话").font(.caption.monospacedDigit()).foregroundStyle(YuduTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      VStack(spacing: 7) {
        HStack {
          Text("阅读进度").font(.caption).foregroundStyle(YuduTheme.muted)
          Spacer()
          Text("\(Int(info.fraction * 100))%")
            .font(.caption.monospacedDigit()).foregroundStyle(YuduTheme.accent)
        }
        ProgressView(value: info.fraction).tint(YuduTheme.accent)
      }
      if let target = Queries.continueTarget(series) {
        NavigationLink(value: BookshelfRoute.reader(series: series, startChapter: target)) {
          HStack(spacing: 10) {
            Image(systemName: "play.fill")
            Text(info.status == .unread ? "开始阅读" : (info.status == .finished ? "再次阅读" : "继续阅读"))
            Text("· \(target.title)").font(.caption).lineLimit(1).opacity(0.75)
          }.padding(.horizontal, 14)
        }.buttonStyle(OrbitalButtonStyle())
      }
      if series.library?.kind == "webdav" || series.library?.kind == "cloud189" { offlineButton }
      if let error = libraryService.prefetchErrors[series.key] {
        NoticeView(title: "离线缓存未完成", message: error, icon: "exclamationmark.triangle", color: YuduTheme.warning)
      }
    }.padding(20).yuduPanel(accent: YuduTheme.accent)
  }

  private var offlineButton: some View {
    let progress = libraryService.prefetchProgress[series.key]
    let cached = WebDAVCache.shared.pinnedSeries.contains(series.key)
    return Button {
      libraryService.togglePrefetch(series)
    } label: {
      HStack(spacing: 8) {
        if let progress {
          ProgressView(value: progress).frame(width: 40).tint(YuduTheme.accent)
          Text("缓存中 \(Int(progress * 100))% · 点按取消")
        } else {
          Image(systemName: cached ? "checkmark.icloud" : "icloud.and.arrow.down")
          Text(cached ? "已离线 · 重新缓存" : "离线缓存整部")
        }
      }.font(.caption).frame(maxWidth: .infinity, minHeight: 44)
    }.buttonStyle(.plain).foregroundStyle(YuduTheme.accent)
  }

  /// 导航与标记按钮是相邻控件，避免嵌套 Button 导致误触跳转。
  private func chapterRow(_ chapter: ChapterEntity) -> some View {
    let completed = chapter.progress?.completed == true
    let current = Queries.continueTarget(series)?.persistentModelID == chapter.persistentModelID
    return HStack(spacing: 0) {
      NavigationLink(value: BookshelfRoute.reader(series: series, startChapter: chapter)) {
        HStack(spacing: 12) {
          Text(String(format: "%02d", chapter.sortIndex + 1))
            .font(.system(.caption, design: .monospaced)).foregroundStyle(current ? YuduTheme.accent : YuduTheme.muted)
            .frame(minWidth: 24)
          VStack(alignment: .leading, spacing: 6) {
            Text(chapter.title).font(.subheadline).foregroundStyle(YuduTheme.text).lineLimit(2)
            Text(chapterStatus(chapter)).font(.caption2).foregroundStyle(completed ? YuduTheme.success : YuduTheme.muted)
          }.frame(maxWidth: .infinity, alignment: .leading)
          if current && !completed { Image(systemName: "play.fill").font(.caption2).foregroundStyle(YuduTheme.accent) }
        }.padding(.leading, 16).padding(.vertical, 16).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Button {
        Queries.setCompleted(chapter, completed: !completed, context: context); refreshTick += 1
      } label: {
        Image(systemName: completed ? "checkmark.circle.fill" : "circle")
          .font(.title3).foregroundStyle(completed ? YuduTheme.success : YuduTheme.muted)
          .frame(width: 48, height: 48)
      }.buttonStyle(.plain)
        .accessibilityLabel("\(chapter.title)，\(completed ? "标记为未读" : "标记为已读")")
    }
  }

  private func chapterStatus(_ chapter: ChapterEntity) -> String {
    if chapter.progress?.completed == true { return "已读完" }
    if let progress = chapter.progress {
      return chapter.pageCount > 0 ? "读到第 \(min(progress.page + 1, chapter.pageCount)) / \(chapter.pageCount) 页" : "正在阅读"
    }
    return chapter.pageCount > 0 ? "\(chapter.pageCount) 页 · 未读" : "未读 · 阅读时获取页数"
  }
}
