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
  @State private var refreshTick = 0

  private struct VolumeGroup: Identifiable {
    var id: String { volume ?? "…" }
    var volume: String?
    var chapters: [ChapterEntity]
  }

  private var orderedChapters: [ChapterEntity] {
    Queries.orderedChapters(series)
  }

  private var groups: [VolumeGroup] {
    var result: [VolumeGroup] = []
    for chapter in orderedChapters {
      let key = chapter.volume
      if let last = result.last, last.volume == key {
        result[result.count - 1].chapters.append(chapter)
      } else {
        result.append(VolumeGroup(volume: key, chapters: [chapter]))
      }
    }
    return result
  }

  var body: some View {
    let _ = refreshTick
    return ScrollViewReader { proxy in
      List {
        hero
        chapterSections
      }
      .listStyle(.insetGrouped)
      .navigationTitle(series.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button {
              Queries.markAllRead(series, context: context)
              refreshTick += 1
            } label: {
              Label("全部标记已读", systemImage: "checkmark.circle")
            }
            Button(role: .destructive) {
              showResetConfirm = true
            } label: {
              Label("重置阅读进度", systemImage: "arrow.counterclockwise")
            }
            if series.library?.kind == "imports" {
              Button(role: .destructive) {
                showDeleteConfirm = true
              } label: {
                Label("删除该漫画（含导入的文件）", systemImage: "trash")
              }
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
      .onAppear {
        // 定位续读话：展开所在卷并滚动过去
        if let target = Queries.continueTarget(series) {
          let key = target.volume ?? "…"
          if collapsedVolumes.contains(key) {
            collapsedVolumes.remove(key)
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation {
              proxy.scrollTo(target.persistentModelID, anchor: .center)
            }
          }
        }
      }
      .confirmationDialog("重置阅读进度？", isPresented: $showResetConfirm, titleVisibility: .visible) {
        Button("重置", role: .destructive) {
          Queries.resetProgress(series, context: context)
          refreshTick += 1
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("清空本书所有话的进度记录，不影响文件与统计")
      }
      .confirmationDialog("删除该漫画？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
        Button("删除", role: .destructive) {
          libraryService.removeImportedSeries(series)
          router.bookshelfPath.removeLast()
        }
        Button("取消", role: .cancel) {}
      } message: {
        Text("将删除导入时拷贝的文件与全部进度")
      }
    }
  }

  // MARK: - 作品卡

  private var palette: CoverPalette { CoverPalette.palette(for: series.key) }

  private var hero: some View {
    Section {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .center, spacing: 14) {
          CoverImage(seriesKey: series.key, title: series.title)
            .frame(width: 116, height: 154)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 4)

          VStack(alignment: .leading, spacing: 7) {
            statusPill
            Text(series.title)
              .font(.headline)
              .lineLimit(3)

            let info = Queries.info(series)
            Text("已读 \(info.read) / \(info.total) 话")
              .font(.footnote.monospacedDigit())
              .foregroundStyle(.secondary)

            ProgressView(value: info.fraction)
              .tint(.cinnabar)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        continueButton
        if series.library?.kind == "webdav" || series.library?.kind == "cloud189" {
          offlineButton
        }
      }
      .padding(.vertical, 16)
      .listRowBackground(
        ZStack {
          Color(.secondarySystemGroupedBackground)
          LinearGradient(
            colors: [palette.top.opacity(0.16), palette.bottom.opacity(0.28)],
            startPoint: .topLeading, endPoint: .bottomTrailing
          )
          CoverImage(seriesKey: series.key, title: series.title)
            .blur(radius: 40)
            .opacity(0.16)
        }
        .clipped()
      )
    }
  }

  @ViewBuilder
  private var statusPill: some View {
    let info = Queries.info(series)
    let (text, color): (String, Color) = switch info.status {
    case .finished: ("已读完", .green)
    case .reading: ("在读 · \(Int(info.fraction * 100))%", .cinnabar)
    case .unread: ("未读", Color(.tertiaryLabel))
    }
    Text(text)
      .font(.caption.weight(.semibold))
      .padding(.horizontal, 9)
      .padding(.vertical, 4)
      .background(color.opacity(0.14), in: Capsule())
      .foregroundStyle(color)
  }

  @ViewBuilder
  private var continueButton: some View {
    let info = Queries.info(series)
    let target = Queries.continueTarget(series)
    let targetTitle = target.map { chapterTitle($0) } ?? ""
    let label = info.status == .unread ? "开始阅读" : "继续阅读"
    if let target {
      NavigationLink(
        value: BookshelfRoute.reader(series: series, startChapter: target)
      ) {
        HStack(spacing: 8) {
          Image(systemName: "book.pages")
            .font(.subheadline)
          VStack(spacing: 1) {
            Text(label)
              .font(.subheadline.weight(.semibold))
            if !targetTitle.isEmpty {
              Text(targetTitle)
                .font(.caption2)
                .lineLimit(1)
                .opacity(0.85)
            }
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
      }
      .buttonStyle(.borderedProminent)
    }
  }

  @ViewBuilder
  private var offlineButton: some View {
    let progress = libraryService.prefetchProgress[series.key]
    let cached = WebDAVCache.shared.pinnedSeries.contains(series.key)
    Button {
      libraryService.togglePrefetch(series)
    } label: {
      HStack(spacing: 6) {
        if progress != nil {
          ProgressView(value: progress)
            .frame(height: 12)
          Text("正在缓存 \(Int(progress! * 100))% · 点按取消")
            .font(.caption2)
        } else if cached {
          Image(systemName: "checkmark.icloud.fill")
          Text("已离线")
        } else {
          Image(systemName: "icloud.and.arrow.down")
          Text("离线缓存整部")
        }
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 8)
    }
    .buttonStyle(.bordered)
    .tint(.cinnabar)
  }

  private func chapterTitle(_ chapter: ChapterEntity) -> String {
    if let number = chapter.number {
      let formatted = number.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(number))
        : String(number)
      return "第 \(formatted) 话"
    }
    return chapter.title
  }

  // MARK: - 章节列表

  private var chapterSections: some View {
    Section {
      if orderedChapters.isEmpty {
        Text("没有章节，试试下拉书架重新扫描")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      ForEach(groups) { group in
        DisclosureGroup(isExpanded: bindingFor(group)) {
          ForEach(group.chapters) { chapter in
            chapterRow(chapter)
          }
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "book.closed")
              .font(.footnote)
              .foregroundStyle(.cinnabar.opacity(0.75))
            Text(group.volume.map { "第 \($0) 卷" } ?? "未分卷")
              .font(.subheadline.weight(.medium))
            Spacer()
            Text("\(group.chapters.count) 话")
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text("章节")
    }
  }

  private func bindingFor(_ group: VolumeGroup) -> Binding<Bool> {
    Binding(
      get: { !collapsedVolumes.contains(group.id) },
      set: { expanded in
        if expanded {
          collapsedVolumes.remove(group.id)
        } else {
          collapsedVolumes.insert(group.id)
        }
      }
    )
  }

  private func chapterRow(_ chapter: ChapterEntity) -> some View {
    NavigationLink(
      value: BookshelfRoute.reader(series: series, startChapter: chapter)
    ) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 4) {
          Text(chapter.title)
            .font(.subheadline)
            .lineLimit(1)
          Text(chapterStatus(chapter))
            .font(.caption2)
            .foregroundStyle(chapter.progress?.completed == true ? .green : .secondary)
          if let progress = chapter.progress,
             chapter.progress?.completed != true,
             chapter.pageCount > 0 {
            ProgressView(
              value: Double(progress.page + 1) / Double(chapter.pageCount)
            )
            .tint(.cinnabar)
            .scaleEffect(x: 1, y: 0.5, anchor: .center)
            .padding(.trailing, 40)
          }
        }
        Spacer()
        Button {
          let completed = chapter.progress?.completed == true
          Queries.setCompleted(chapter, completed: !completed, context: context)
          refreshTick += 1
        } label: {
          Image(systemName: chapter.progress?.completed == true
            ? "checkmark.circle.fill"
            : "circle")
            .font(.title3)
            .foregroundStyle(chapter.progress?.completed == true ? .green : Color(.quaternaryLabel))
        }
        .buttonStyle(.plain)
      }
      .id(chapter.persistentModelID)
    }
  }

  private func chapterStatus(_ chapter: ChapterEntity) -> String {
    if chapter.progress?.completed == true {
      return "已读完"
    }
    if let progress = chapter.progress {
      if chapter.pageCount > 0 {
        return "第 \(min(progress.page + 1, chapter.pageCount)) / \(chapter.pageCount) 页"
      }
      return "在读"
    }
    return chapter.pageCount > 0 ? "\(chapter.pageCount) 页" : "页数待确认"
  }
}
