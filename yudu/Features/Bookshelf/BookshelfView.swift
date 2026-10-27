import SwiftUI
import SwiftData

struct BookshelfView: View {
  @Query(sort: \SeriesEntity.title) private var allSeries: [SeriesEntity]
  @Query(sort: \LibraryEntity.createdAt) private var libraries: [LibraryEntity]
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService

  enum Filter: String, CaseIterable, Identifiable {
    case all = "全部", unread = "未读", reading = "在读", finished = "已读完"
    var id: String { rawValue }
    func includes(_ status: Queries.ShelfStatus) -> Bool {
      switch self {
      case .all: true
      case .unread: status == .unread
      case .reading: status == .reading
      case .finished: status == .finished
      }
    }
  }

  enum Sort: String, CaseIterable {
    case recent = "最近阅读", added = "最近添加", title = "名称排序"
  }

  @State private var filter: Filter = .all
  @State private var searchText = ""
  @State private var sourceKey: String?
  @AppStorage("shelfSort") private var sortRaw = Sort.recent.rawValue
  @AppStorage("shelfListLayout") private var listLayout = false

  private var infos: [Queries.SeriesInfo] { allSeries.map { Queries.info($0) } }
  private var filtered: [Queries.SeriesInfo] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let result = infos.filter {
      filter.includes($0.status)
        && (sourceKey == nil || $0.series.library?.key == sourceKey)
        && (query.isEmpty || $0.series.title.localizedCaseInsensitiveContains(query))
    }
    return result.sorted { a, b in
      switch Sort(rawValue: sortRaw) ?? .recent {
      case .recent:
        let lhs = a.series.lastReadAt ?? .distantPast
        let rhs = b.series.lastReadAt ?? .distantPast
        if lhs != rhs { return lhs > rhs }
      case .added:
        if a.series.addedAt != b.series.addedAt { return a.series.addedAt > b.series.addedAt }
      case .title: break
      }
      return a.series.title.localizedStandardCompare(b.series.title) == .orderedAscending
    }
  }

  var body: some View {
    @Bindable var router = router
    NavigationStack(path: $router.bookshelfPath) {
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          heading
          if libraryService.isScanning {
            HStack(spacing: 10) {
              ProgressView().tint(YuduTheme.accent)
              Text("正在扫描书库与生成封面…").font(.caption)
            }
            .foregroundStyle(YuduTheme.muted)
          }
          if allSeries.isEmpty {
            emptyState
          } else {
            if searchText.isEmpty && sourceKey == nil { continueSection }
            collectionSection
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: 1000)
        .frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("书架")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { YuduWordmark() }
        ToolbarItem(placement: .topBarTrailing) {
          Button { router.showImport = true } label: {
            Image(systemName: "plus").font(.body.weight(.medium)).frame(width: 44, height: 44)
          }
          .accessibilityLabel("导入漫画或连接书库")
        }
      }
      .searchable(text: $searchText, prompt: "搜索你的漫画")
      .navigationDestination(for: BookshelfRoute.self) { route in
        switch route {
        case .series(let series): SeriesDetailView(series: series)
        case .reader(let series, let chapter, let token):
          ReaderView(series: series, startChapter: chapter, token: token)
        }
      }
      .refreshable { await libraryService.rescanAll() }
      .onChange(of: libraries.map(\.key)) { _, keys in
        if let sourceKey, !keys.contains(sourceKey) { self.sourceKey = nil }
      }
      .task {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-yuduShowImport") { router.showImport = true }
        #endif
      }
    }
  }

  private var heading: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("YOUR PRIVATE UNIVERSE")
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .tracking(2.5).foregroundStyle(YuduTheme.accent)
      Text("故事，在此汇聚。")
        .font(.system(.largeTitle, design: .rounded, weight: .semibold))
        .minimumScaleFactor(0.7)
      Text(allSeries.isEmpty ? "为你的第一个故事，留一个位置。" : "\(allSeries.count) 部漫画 · \(infos.filter { $0.status == .reading }.count) 部在读")
        .font(.subheadline).foregroundStyle(YuduTheme.muted)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var continueSection: some View {
    let items = Queries.continueItems(allSeries)
    if let first = items.first {
      VStack(alignment: .leading, spacing: 14) {
        SectionHeading(title: "接着上次的故事", eyebrow: "CONTINUE READING")
        NavigationLink(value: BookshelfRoute.reader(series: first.series, startChapter: first.chapter)) {
          ContinueCard(item: first, featured: true)
        }
        .buttonStyle(.plain)
        if items.count > 1 {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(Array(items.dropFirst())) { item in
                NavigationLink(value: BookshelfRoute.reader(series: item.series, startChapter: item.chapter)) {
                  ContinueCard(item: item).frame(width: 272)
                }
                .buttonStyle(.plain)
              }
            }
          }
        }
      }
    }
  }

  private var collectionSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        SectionHeading(title: "我的收藏", eyebrow: "COLLECTION", detail: "\(filtered.count) 部")
        Menu {
          Picker("排序", selection: $sortRaw) {
            ForEach(Sort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
          }
          Divider()
          Button(listLayout ? "切换封面网格" : "切换详细列表", systemImage: listLayout ? "square.grid.2x2" : "list.bullet") {
            listLayout.toggle()
          }
        } label: {
          Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
        }
        .accessibilityLabel("书架排序与布局")
      }
      filterChips
      HStack {
        Menu {
          Button("所有来源") { sourceKey = nil }
          ForEach(libraries) { library in
            Button { sourceKey = library.key } label: {
              Label(library.name, systemImage: library.sourceIcon)
            }
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "square.stack.3d.up")
            Text(libraries.first(where: { $0.key == sourceKey })?.name ?? "所有来源").lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9))
          }
          .font(.caption).frame(minHeight: 44)
        }
        Spacer()
        Text(sortRaw).font(.caption2).foregroundStyle(YuduTheme.muted)
      }
      .padding(.vertical, -8)
      if filtered.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "sparkle.magnifyingglass").font(.largeTitle).foregroundStyle(YuduTheme.muted)
          Text("没有匹配的漫画").font(.headline)
          Text("试试其他关键词、阅读状态或来源。")
            .font(.caption).foregroundStyle(YuduTheme.muted)
          Button("清除筛选") { searchText = ""; filter = .all; sourceKey = nil }
            .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32).yuduPanel()
      } else if listLayout {
        LazyVStack(spacing: 12) {
          ForEach(filtered, id: \.series.persistentModelID) { info in
            NavigationLink(value: BookshelfRoute.series(info.series)) { ShelfRow(info: info) }
              .buttonStyle(.plain)
          }
        }
      } else {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 98, maximum: 168), spacing: 14)], alignment: .leading, spacing: 22) {
          ForEach(filtered, id: \.series.persistentModelID) { info in
            NavigationLink(value: BookshelfRoute.series(info.series)) { CoverCard(info: info) }
              .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private var filterChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Filter.allCases) { chip in
          let selected = filter == chip
          Button { filter = chip } label: {
            HStack(spacing: 6) {
              Text(chip.rawValue)
              Text("\(infos.filter { chip.includes($0.status) }.count)")
                .font(.caption2.monospacedDigit()).opacity(0.7)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(selected ? YuduTheme.accent : YuduTheme.surface, in: Capsule())
            .foregroundStyle(selected ? YuduTheme.background : YuduTheme.muted)
            .overlay { Capsule().strokeBorder(selected ? .clear : YuduTheme.line, lineWidth: 0.5) }
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(selected ? .isSelected : [])
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 22) {
      ZStack {
        Circle().stroke(YuduTheme.line, lineWidth: 1).frame(width: 200, height: 200)
        Circle().stroke(YuduTheme.line.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 8]))
          .frame(width: 260, height: 260)
        OrbitalEmblem(size: 108)
        Circle().fill(YuduTheme.accent).frame(width: 7, height: 7).offset(x: 95, y: -31)
        Image(systemName: "sparkle").foregroundStyle(YuduTheme.violet).offset(x: -99, y: 70)
      }
      .frame(height: 260).accessibilityHidden(true)
      VStack(spacing: 9) {
        Text("开启你的阅读宇宙").font(.title2.weight(.semibold))
        Text("导入本地漫画，或连接云端书库。\n每一段故事，都有自己的轨道。")
          .font(.subheadline).foregroundStyle(YuduTheme.muted)
          .multilineTextAlignment(.center).lineSpacing(5)
      }
      Button { router.showImport = true } label: { Label("添加第一部漫画", systemImage: "plus") }
        .buttonStyle(OrbitalButtonStyle())
      Text("ZIP / CBZ / PDF · 文件夹 · WebDAV · 天翼云盘")
        .font(.caption2).foregroundStyle(YuduTheme.muted).multilineTextAlignment(.center)
    }
    .padding(.bottom, 20)
  }
}

struct CoverCard: View {
  let info: Queries.SeriesInfo
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      CoverImage(seriesKey: info.series.key, title: info.series.title)
        .aspectRatio(3.0 / 4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
          if info.status == .finished {
            Image(systemName: "checkmark.circle.fill")
              .symbolRenderingMode(.palette).foregroundStyle(YuduTheme.success, YuduTheme.background)
              .padding(7)
          }
        }
        .overlay(alignment: .bottom) {
          if info.status == .reading {
            ProgressView(value: info.fraction).tint(YuduTheme.accent)
              .background(.black.opacity(0.4)).padding(.horizontal, 8).padding(.bottom, 8)
          }
        }
      Text(info.series.title).font(.subheadline.weight(.medium)).lineLimit(2)
        .foregroundStyle(YuduTheme.text).frame(maxWidth: .infinity, alignment: .leading)
      Text("\(info.total) 话 · \(info.status.label)")
        .font(.caption2).foregroundStyle(YuduTheme.muted)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct ShelfRow: View {
  let info: Queries.SeriesInfo
  var body: some View {
    HStack(spacing: 14) {
      CoverImage(seriesKey: info.series.key, title: info.series.title)
        .frame(width: 58, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
      VStack(alignment: .leading, spacing: 7) {
        Text(info.series.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(YuduTheme.text)
        Text("\(info.total) 话 · \(info.series.library?.name ?? "本机")")
          .font(.caption).foregroundStyle(YuduTheme.muted).lineLimit(1)
        StatusPill(text: info.status.label, color: info.status.color)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(.caption).foregroundStyle(YuduTheme.muted)
    }
    .padding(12).yuduPanel()
  }
}

struct ContinueCard: View {
  let item: Queries.ContinueItem
  var featured = false
  private var fraction: Double {
    item.pageCount > 0 ? min(Double(item.page + 1) / Double(item.pageCount), 1) : 0
  }
  var body: some View {
    HStack(spacing: featured ? 18 : 12) {
      CoverImage(seriesKey: item.series.key, title: item.series.title)
        .frame(width: featured ? 86 : 56, height: featured ? 116 : 76)
        .clipShape(RoundedRectangle(cornerRadius: 10))
      VStack(alignment: .leading, spacing: 9) {
        if featured {
          Text("上次读到这里")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(YuduTheme.accent)
        }
        Text(item.series.title).font(featured ? .headline : .subheadline.weight(.semibold))
          .foregroundStyle(YuduTheme.text).lineLimit(2)
        Text(item.chapter.title).font(.caption).foregroundStyle(YuduTheme.muted).lineLimit(1)
        ProgressView(value: fraction).tint(YuduTheme.accent)
        Text(item.pageCount > 0 ? "第 \(min(item.page + 1, item.pageCount)) / \(item.pageCount) 页" : "继续下一话")
          .font(.caption2.monospacedDigit()).foregroundStyle(YuduTheme.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "play.fill").font(.system(size: 12))
        .foregroundStyle(YuduTheme.background).frame(width: 36, height: 36)
        .background(YuduTheme.accent, in: Circle())
    }
    .padding(featured ? 18 : 14).yuduPanel(accent: featured ? YuduTheme.accent : nil)
    .accessibilityElement(children: .combine)
    .accessibilityHint("继续阅读此漫画")
  }
}
