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
          VStack(alignment: .leading, spacing: 18) {
            continueSection
            filterChips
            coverGrid
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 24)
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
        }
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
    let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 14)]
    return LazyVGrid(columns: columns, spacing: 18) {
      ForEach(filtered, id: \.series.persistentModelID) { info in
        NavigationLink(value: BookshelfRoute.series(info.series)) {
          CoverCard(info: info)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "books.vertical")
        .font(.system(size: 44))
        .foregroundStyle(.tertiary)
      Text("书架还是空的")
        .font(.headline)
      Text("导入 zip / cbz / PDF 文件，或授权一个漫画文件夹")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Button {
        showImport = true
      } label: {
        Label("导入漫画", systemImage: "plus")
          .padding(.horizontal, 18)
          .padding(.vertical, 10)
      }
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, minHeight: 480)
  }
}

// MARK: - 封面卡片

struct CoverCard: View {
  let info: Queries.SeriesInfo

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      CoverImage(seriesKey: info.series.key)
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
          statusBadge
        }
        .overlay(alignment: .bottom) {
          if info.status == .reading, info.fraction > 0.005 {
            GeometryReader { geo in
              ZStack(alignment: .leading) {
                Rectangle().fill(.ultraThinMaterial.opacity(0.5))
                Rectangle()
                  .fill(Color.cinnabar)
                  .frame(width: geo.size.width * info.fraction)
              }
            }
            .frame(height: 3)
          }
        }
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
      Text("已读完")
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.green.opacity(0.85), in: Capsule())
        .foregroundStyle(.white)
    case .reading:
      EmptyView()
    case .unread:
      EmptyView()
    }
  }
}

// MARK: - 继续阅读卡

struct ContinueCard: View {
  let item: Queries.ContinueItem

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      CoverImage(seriesKey: item.series.key)
        .frame(width: 92, height: 122)
        .clipShape(RoundedRectangle(cornerRadius: 8))
      Text(item.series.title)
        .font(.footnote.weight(.medium))
        .lineLimit(1)
      Text(item.chapter.title)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      if item.pageCount > 0 {
        Text("第 \(min(item.page + 1, item.pageCount)) / \(item.pageCount) 页")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.cinnabar)
      }
    }
    .frame(width: 92)
  }
}

// MARK: - 封面图（磁盘缓存 + 生成中重试）

struct CoverImage: View {
  let seriesKey: String
  @Environment(LibraryService.self) private var libraryService
  @State private var image: UIImage?

  var body: some View {
    ZStack {
      Rectangle().fill(Color(.tertiarySystemFill))
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "book.closed")
          .font(.title3)
          .foregroundStyle(.tertiary)
      }
    }
    .task(id: "\(seriesKey)#\(libraryService.coverVersion)") {
      // 封面可能在扫描后几秒内生成，带重试
      for _ in 0..<24 {
        if let loaded = UIImage(contentsOfFile: CoverStore.shared.coverURL(seriesKey: seriesKey).path) {
          image = loaded
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }
}
