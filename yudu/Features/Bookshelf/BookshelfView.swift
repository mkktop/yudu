import SwiftUI
import SwiftData

// MARK: - 书架（首页）

struct BookshelfView: View {
  @Query(sort: \SeriesEntity.title) private var allSeries: [SeriesEntity]
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService

  enum Filter: String, CaseIterable, Identifiable {
    case all = "全部"
    case unread = "未读"
    case reading = "在读"
    case finished = "已读完"

    var id: String { rawValue }
  }

  @State private var filter: Filter = .all
  @State private var searchText = ""
  @State private var showImport = false

  private var filtered: [Queries.SeriesInfo] {
    var list = allSeries.map { Queries.info($0) }
    switch filter {
    case .all: break
    case .unread: list = list.filter { $0.status == .unread }
    case .reading: list = list.filter { $0.status == .reading }
    case .finished: list = list.filter { $0.status == .finished }
    }
    let query = searchText.trimmingCharacters(in: .whitespaces)
    if !query.isEmpty {
      list = list.filter { $0.series.title.localizedCaseInsensitiveContains(query) }
    }
    return list
  }

  var body: some View {
    @Bindable var router = router
    return NavigationStack(path: $router.bookshelfPath) {
      ScrollView {
        if allSeries.isEmpty {
          emptyState
        } else {
          VStack(alignment: .leading, spacing: 20) {
            continueSection
            filterChips
            coverGrid
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 28)
        }
      }
      .background(Color(.systemGroupedBackground))
      .navigationTitle("书架")
      .searchable(text: $searchText, prompt: "搜索漫画")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showImport = true
          } label: {
            Image(systemName: "plus")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button {
              Task { await libraryService.rescanAll() }
            } label: {
              Label("重新扫描全部", systemImage: "arrow.triangle.2.circlepath")
            }
          } label: {
            Image(systemName: "ellipsis.circle")
          }
        }
      }
      .navigationDestination(for: BookshelfRoute.self) { route in
        switch route {
        case .series(let series):
          SeriesDetailView(series: series)
        case .reader(let series, let chapter, let token):
          ReaderView(series: series, startChapter: chapter, token: token)
        }
      }
      .sheet(isPresented: $showImport) {
        ImportSheet()
          .environment(libraryService)
      }
      .refreshable {
        await libraryService.rescanAll()
      }
      .task {
        #if DEBUG
        // 自测辅助：-yuduShowImport 直接弹出导入面板供截图
        if ProcessInfo.processInfo.arguments.contains("-yuduShowImport") {
          showImport = true
        }
        #endif
      }
      }
    }

  // MARK: - 继续阅读

  @ViewBuilder
  private var continueSection: some View {
    let items = Queries.continueItems(allSeries)
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("继续阅读")
          .font(.headline)
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
            ForEach(items) { item in
              NavigationLink(
                value: BookshelfRoute.reader(series: item.series, startChapter: item.chapter)
              ) {
                ContinueCard(item: item)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.vertical, 4)
          .padding(.horizontal, 2)
        }
        .padding(.horizontal, -2)
      }
    }
  }

  // MARK: - 筛选

  private var filterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Filter.allCases) { chip in
          Button {
            withAnimation(.snappy) { filter = chip }
          } label: {
            Text(chip.rawValue)
              .font(.footnote.weight(.medium))
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(
                filter == chip ? AnyShapeStyle(Color.cinnabar) : AnyShapeStyle(Color(.secondarySystemBackground)),
                in: Capsule()
              )
              .foregroundStyle(filter == chip ? .white : .primary)
            }
          }
          .buttonStyle(.plain)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

  // MARK: - 封面墙

  private var coverGrid: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("全部漫画")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Text("\(filtered.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
        Spacer()
      }
      let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)]
      LazyVGrid(columns: columns, spacing: 18) {
        ForEach(filtered, id: \.series.persistentModelID) { info in
          NavigationLink(value: BookshelfRoute.series(info.series)) {
            CoverCard(info: info)
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 18) {
      EmptyShelfIllustration()
        .padding(.bottom, 6)
      Text("书架还是空的")
        .font(.title3.weight(.semibold))
      Text("导入 zip / cbz / PDF 文件，或授权一个漫画文件夹\n也可以连接 WebDAV、天翼云盘在线阅读")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .lineSpacing(3)
      Button {
        showImport = true
      } label: {
        Label("导入漫画", systemImage: "plus")
          .padding(.horizontal, 22)
          .padding(.vertical, 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(.cinnabar)
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, minHeight: 520)
  }
}

// MARK: - 空书架插画（三册斜排的书）

private struct EmptyShelfIllustration: View {
  var body: some View {
    ZStack {
      cover("雪", key: "empty-a")
        .rotationEffect(.degrees(-9))
        .offset(x: -62, y: 6)
      cover("海", key: "empty-b")
        .rotationEffect(.degrees(8))
        .offset(x: 60, y: 10)
      cover("雨", key: "empty-c")
        .shadow(color: .black.opacity(0.22), radius: 10, y: 6)
    }
    .frame(height: 168)
  }

  private func cover(_ title: String, key: String) -> some View {
    PlaceholderCoverView(title: title, key: key)
      .frame(width: 82, height: 110)
      .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

// MARK: - 封面卡片

struct CoverCard: View {
  let info: Queries.SeriesInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      CoverImage(seriesKey: info.series.key, title: info.series.title)
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
          statusBadge
        }
        .overlay(alignment: .bottom) {
          if info.status == .reading, info.fraction > 0.005 {
            GeometryReader { geo in
              ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.35))
                Rectangle()
                  .fill(Color.cinnabar)
                  .frame(width: geo.size.width * info.fraction)
              }
            }
            .frame(height: 3)
          }
        }
        .shadow(color: .black.opacity(0.18), radius: 7, y: 4)
      Text(info.series.title)
        .font(.footnote)
        .lineLimit(2)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private var statusBadge: some View {
    switch info.status {
    case .finished:
      Image(systemName: "checkmark")
        .font(.caption2.weight(.bold))
        .padding(5)
        .background(.green.opacity(0.9), in: Circle())
        .foregroundStyle(.white)
        .padding(6)
    case .reading:
      EmptyView()
    case .unread:
      EmptyView()
    }
  }
}

// MARK: - 继续阅读卡（宽卡）

struct ContinueCard: View {
  let item: Queries.ContinueItem

  var body: some View {
    HStack(spacing: 12) {
      CoverImage(seriesKey: item.series.key, title: item.series.title)
        .frame(width: 62, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.16), radius: 4, y: 2)

      VStack(alignment: .leading, spacing: 4) {
        Text(item.series.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Text(item.chapter.title)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer(minLength: 0)
        HStack(spacing: 6) {
          if item.pageCount > 0 {
            ProgressView(value: Double(item.page + 1) / Double(max(item.pageCount, 1)))
              .tint(.cinnabar)
            Text("\(min(item.page + 1, item.pageCount))/\(item.pageCount)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          } else {
            Text("开始阅读")
              .font(.caption2)
              .foregroundStyle(.cinnabar)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Image(systemName: "play.circle.fill")
        .font(.title2)
        .foregroundStyle(.cinnabar)
        .symbolRenderingMode(.hierarchical)
    }
    .padding(12)
    .frame(width: 272, height: 108)
    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
  }
}
