import SwiftUI
import SwiftData

struct ReaderView: View {
  let series: SeriesEntity
  let startChapter: ChapterEntity?
  /// 每次进入生成新值；task(id:) 据此重建阅读会话（视图复用时也能响应）
  let token: UUID

  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @Environment(LibraryService.self) private var libraryService
  /// 横屏（iPhone 紧凑高度）用单行紧凑控制栏，避免菜单盖住半屏
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  @State private var vm: ReaderViewModel?
  @State private var eyeCare = EyeCare.load()
  @State private var showJumpSheet = false
  @State private var showTOC = false
  @State private var showReaderSettings = false

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if let vm {
        readerContent(vm)
        eyeCareOverlay
        directionHint(vm)
        chrome(vm)
      } else {
        ProgressView().tint(.white)
      }
    }
    .toolbar(.hidden, for: .navigationBar)
    .toolbar(.hidden, for: .tabBar)
    .preferredColorScheme(.dark)
    .statusBarHidden(vm?.chromeVisible == false)
    .onAppear { ReaderActivity.begin() }
    .task(id: token) {
      vm?.stop()
      let model = ReaderViewModel(
        series: series, startChapter: startChapter, context: context, libraryService: libraryService
      )
      vm = model
      #if DEBUG
      ReaderProbe.currentViewModel = model
      #endif
      model.start()
    }
    .onDisappear {
      ReaderActivity.end()
      vm?.stop()
    }
    .sheet(isPresented: $showJumpSheet) {
      if let vm {
        JumpSheet(vm: vm)
      }
    }
    .sheet(isPresented: $showReaderSettings) {
      if let vm { ReaderSettingsSheet(vm: vm, eyeCare: $eyeCare) }
    }
    .sheet(isPresented: $showTOC) {
      if let vm {
        TOCSheet(series: series, vm: vm)
      }
    }
  }

  // MARK: - 内容区

  @ViewBuilder
  private func readerContent(_ vm: ReaderViewModel) -> some View {
    if vm.isLoading {
      ProgressView().tint(.white)
    } else if let error = vm.errorMessage {
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.largeTitle)
          .foregroundStyle(.white.opacity(0.5))
        Text(error)
          .foregroundStyle(.white.opacity(0.8))
          .multilineTextAlignment(.center)
        Button("重试") { vm.start() }
          .buttonStyle(.borderedProminent).tint(YuduTheme.accent)
        Button("返回上一页") { dismiss() }
          .buttonStyle(.bordered)
          .tint(.white)
      }
      .padding(32)
    } else if vm.effectiveMode == .webtoon {
      WebtoonView(vm: vm)
        .id(vm.current?.path ?? "")
        .ignoresSafeArea()
    } else if let source = vm.source, vm.pageCount > 0 {
      ReaderPager(
        pageCount: vm.pageCount,
        page: vm.page,
        rtl: vm.prefs.rtl,
        fit: vm.prefs.fit,
        source: source,
        sourceID: vm.sourceID,
        isRemote: vm.isRemoteSource,
        onPageChanged: { vm.setPage($0) },
        onPageSize: { index, size in vm.recordPageSize(index: index, size: size) },
        onTapSide: { side in
          switch side {
          case .center:
            vm.toggleChrome()
          case .left:
            vm.step(vm.prefs.rtl ? 1 : -1)
          case .right:
            vm.step(vm.prefs.rtl ? -1 : 1)
          }
        }
      )
      .id(vm.current?.path ?? "")
      .ignoresSafeArea()
    }
  }

  // MARK: - 护眼滤镜

  @ViewBuilder
  private var eyeCareOverlay: some View {
    let brightness = eyeCare.effectiveBrightness
    let warmth = eyeCare.effectiveWarmth
    ZStack {
      if brightness < 1.0 {
        Color.black.opacity(1.0 - brightness)
      }
      if warmth > 0.001 {
        Color.orange.opacity(warmth * 0.5)
          .blendMode(.multiply)
      }
    }
    .allowsHitTesting(false)
    .ignoresSafeArea()
  }

  // MARK: - 方向提示

  @ViewBuilder
  private func directionHint(_ vm: ReaderViewModel) -> some View {
    if vm.showDirectionHint && vm.effectiveMode == .single {
      HStack(spacing: 8) {
        Image(systemName: vm.prefs.rtl ? "arrow.left" : "arrow.right")
        Text(vm.prefs.rtl ? "从右往左 · 日漫" : "从左往右")
      }
      .font(.callout.weight(.medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.black.opacity(0.62), in: Capsule())
      .transition(.opacity)
    }
  }

  // MARK: - 工具栏

  /// 模拟器冒烟测试用：竖屏也能强制渲染横屏紧凑栏，验证布局不溢出
  private var compactChrome: Bool {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-yuduCompactChrome") { return true }
    #endif
    return verticalSizeClass == .compact
  }

  @ViewBuilder
  private func chrome(_ vm: ReaderViewModel) -> some View {
    let compact = compactChrome
    VStack(spacing: 0) {
      if vm.chromeVisible {
        topBar(vm, compact: compact)
          .transition(.move(edge: .top).combined(with: .opacity))
        Spacer(minLength: 0)
        if compact {
          compactBottomBar(vm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
          bottomBar(vm)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
      } else {
        Spacer(minLength: 0)
      }
    }
    .animation(.easeInOut(duration: 0.22), value: vm.chromeVisible)
  }

  private func topBar(_ vm: ReaderViewModel, compact: Bool) -> some View {
    HStack(spacing: compact ? 8 : 12) {
      Button { dismiss() } label: {
        chromeCircle("chevron.left", compact: compact)
      }.accessibilityLabel("退出阅读")
      VStack(alignment: .leading, spacing: compact ? 1 : 5) {
        Text(vm.current?.seriesTitle ?? series.title)
          .font(compact ? .caption2 : .caption).foregroundStyle(YuduTheme.muted).lineLimit(1)
        Text(vm.current?.title ?? "正在打开…")
          .font(compact ? .footnote.weight(.medium) : .subheadline.weight(.medium))
          .foregroundStyle(YuduTheme.text).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
      Button { showReaderSettings = true } label: {
        chromeCircle("slider.horizontal.3", compact: compact)
      }.accessibilityLabel("阅读设置与护眼")
      Button { vm.hideChrome() } label: {
        chromeCircle("chevron.down", compact: compact)
      }.accessibilityLabel("收起菜单")
    }
    .foregroundStyle(YuduTheme.accent)
    .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 4 : 8)
    .background {
      LinearGradient(colors: [YuduTheme.background.opacity(0.98), YuduTheme.background.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea(edges: compact ? [.top, .horizontal] : .top)
    }
  }

  private func chromeCircle(_ name: String, compact: Bool) -> some View {
    Image(systemName: name)
      .font(.system(size: compact ? 15 : 17, weight: .regular))
      .frame(width: compact ? 40 : 44, height: compact ? 40 : 44)
      .background(YuduTheme.surface.opacity(0.94), in: Circle())
  }

  private func bottomBar(_ vm: ReaderViewModel) -> some View {
    VStack(spacing: 14) {
      HStack {
        Button {
          Task { await vm.goToPreviousChapter() }
        } label: { Label("上一话", systemImage: "backward.end").font(.caption).frame(minHeight: 44) }
          .disabled(vm.prevChapter == nil || vm.isLoading)
          .opacity(vm.prevChapter == nil || vm.isLoading ? 0.35 : 1)
        Spacer()
        Button { showJumpSheet = true } label: {
          HStack(spacing: 5) {
            Text("\(vm.pageCount > 0 ? vm.page + 1 : 0) / \(vm.pageCount)").font(.caption.monospacedDigit())
            Image(systemName: "chevron.down").font(.system(size: 8))
          }.frame(minWidth: 75, minHeight: 44)
        }
        .disabled(vm.pageCount == 0 || vm.isLoading)
        .accessibilityLabel("当前第 \(vm.page + 1) 页，共 \(vm.pageCount) 页，点按跳页")
        Spacer()
        Button {
          Task { await vm.goToChapter(offset: 1, landing: 0) }
        } label: { Label("下一话", systemImage: "forward.end").font(.caption).frame(minHeight: 44) }
          .disabled(vm.nextChapter == nil || vm.isLoading)
          .opacity(vm.nextChapter == nil || vm.isLoading ? 0.35 : 1)
      }
      if vm.effectiveMode == .single, vm.pageCount > 1 {
        PageScrubber(vm: vm)
      } else if vm.pageCount > 0 {
        ProgressView(value: Double(vm.page + 1) / Double(vm.pageCount)).tint(YuduTheme.accent)
      }
      HStack(spacing: 0) {
        controlButton(icon: "list.bullet", label: "目录") { showTOC = true }
        Spacer(minLength: 0)
        if vm.isPDF {
          Text("PDF · 连续阅读").font(.caption).foregroundStyle(YuduTheme.muted)
        } else {
          controlButton(icon: vm.prefs.mode == .single ? "rectangle.portrait" : "rectangle.portrait.on.rectangle.portrait", label: vm.prefs.mode.label) {
            vm.setMode(vm.prefs.mode == .single ? .webtoon : .single)
          }
          Spacer(minLength: 0)
          controlButton(icon: fitIcon(vm.prefs.fit), label: vm.prefs.fit.label) {
            vm.setFit(nextFit(vm.prefs.fit))
          }
        }
        Spacer(minLength: 0)
        controlButton(icon: "sun.max", label: "护眼") { showReaderSettings = true }
      }
      .disabled(vm.isLoading)
    }
    .foregroundStyle(YuduTheme.accent)
    .padding(.horizontal, 20).padding(.bottom, 10).padding(.top, 2)
    .background {
      YuduTheme.surface.opacity(0.97)
        .overlay(alignment: .top) { Rectangle().fill(YuduTheme.accent.opacity(0.25)).frame(height: 0.5) }
        .ignoresSafeArea(edges: .bottom)
    }
  }

  private func controlButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: icon).font(.system(size: 18, weight: .light))
        Text(label).font(.caption2).foregroundStyle(YuduTheme.muted)
      }.frame(minWidth: 52, minHeight: 48).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(label)
  }

  /// 横屏单行控制栏：把竖屏的三行压成一行，高度从约半屏降到约 50pt
  private func compactBottomBar(_ vm: ReaderViewModel) -> some View {
    HStack(spacing: 2) {
      compactControl(
        icon: "backward.end", label: "上一话",
        disabled: vm.prevChapter == nil || vm.isLoading
      ) { Task { await vm.goToPreviousChapter() } }

      Button { showJumpSheet = true } label: {
        HStack(spacing: 3) {
          Text(vm.pageCount > 0 ? "\(vm.page + 1) / \(vm.pageCount)" : "0 / 0")
            .font(.footnote.monospacedDigit())
          Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
        }
        .frame(minWidth: 62, minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(vm.pageCount == 0 || vm.isLoading)
      .opacity(vm.pageCount == 0 || vm.isLoading ? 0.35 : 1)
      .accessibilityLabel("当前第 \(vm.page + 1) 页，共 \(vm.pageCount) 页，点按跳页")

      compactControl(
        icon: "forward.end", label: "下一话",
        disabled: vm.nextChapter == nil || vm.isLoading
      ) { Task { await vm.goToChapter(offset: 1, landing: 0) } }

      if vm.effectiveMode == .single, vm.pageCount > 1 {
        // maxWidth 让滑条吃掉单行里的剩余宽度（否则只占 Slider 的固有宽度）
        PageScrubber(vm: vm, compact: true)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 8)
      } else if vm.pageCount > 0 {
        ProgressView(value: Double(vm.page + 1) / Double(vm.pageCount))
          .tint(YuduTheme.accent)
          .frame(maxWidth: .infinity)
          .padding(.horizontal, 16)
      }

      compactControl(icon: "list.bullet", label: "目录") { showTOC = true }
      if !vm.isPDF {
        compactControl(
          icon: vm.prefs.mode == .single ? "rectangle.portrait" : "rectangle.portrait.on.rectangle.portrait",
          label: vm.prefs.mode.label
        ) { vm.setMode(vm.prefs.mode == .single ? .webtoon : .single) }
        compactControl(icon: fitIcon(vm.prefs.fit), label: vm.prefs.fit.label) {
          vm.setFit(nextFit(vm.prefs.fit))
        }
      }
      compactControl(icon: "sun.max", label: "护眼") { showReaderSettings = true }
    }
    .foregroundStyle(YuduTheme.accent)
    .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
    .background {
      YuduTheme.surface.opacity(0.97)
        .overlay(alignment: .top) { Rectangle().fill(YuduTheme.accent.opacity(0.25)).frame(height: 0.5) }
        .ignoresSafeArea(edges: [.bottom, .horizontal])
    }
  }

  private func compactControl(
    icon: String, label: String, disabled: Bool = false, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .light))
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabled)
    .opacity(disabled ? 0.35 : 1)
    .accessibilityLabel(label)
  }

  private func fitIcon(_ fit: ReaderFit) -> String {
    switch fit {
    case .width: "arrow.left.and.right"
    case .height: "arrow.up.and.down"
    case .page: "aspectratio"
    }
  }

  /// 三种适配循环切换（之前只会在适宽/适高之间来回，永远回不到整页）
  private func nextFit(_ fit: ReaderFit) -> ReaderFit {
    switch fit {
    case .page: .width
    case .width: .height
    case .height: .page
    }
  }

  #if DEBUG
  static func logSession(token: UUID, mode: ReaderMode, chapter: String) {
    Self.diag("task token=\(token.uuidString.prefix(8)) mode=\(mode.rawValue) chapter=\(chapter)")
  }

  static func logRestore(_ line: String) {
    Self.diag(line)
  }

  private static func diag(_ line: String) {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
      .appendingPathComponent("selftest", isDirectory: true)
    let url = dir.appendingPathComponent("reader-diag.txt")
    let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try? (old + line + "\n").data(using: .utf8)?.write(to: url)
  }
  #endif

  // MARK: - 跳页

  /// 单页模式页码滑条：拖动中只改本地值，松手才落页（避免连翻解码）
  private struct PageScrubber: View {
    let vm: ReaderViewModel
    /// 横屏单行模式：页码已显示在左侧，滑条不再重复首尾数字
    var compact = false
    @State private var scrubbing = false
    @State private var localPage: Double = 0

    var body: some View {
      HStack(spacing: compact ? 0 : 12) {
        if !compact {
          Text("\(Int(localPage.rounded()) + 1)")
            .font(.footnote.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
            .frame(width: 34, alignment: .leading)
        }
        Slider(
          value: $localPage,
          in: 0...Double(max(vm.pageCount - 1, 0))
        ) { editing in
          scrubbing = editing
          if !editing {
            vm.setPage(Int(localPage.rounded()))
          }
        }
        .tint(YuduTheme.accent)
        .accessibilityLabel("阅读页码")
        if !compact {
          Text("\(vm.pageCount)")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
            .frame(width: 34, alignment: .trailing)
        }
      }
      .onAppear { localPage = Double(vm.page) }
      .onChange(of: vm.page) { _, new in
        if !scrubbing { localPage = Double(new) }
      }
    }
  }

  private struct JumpSheet: View {
    let vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var validPage: Int? {
      guard let page = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            (1...max(vm.pageCount, 1)).contains(page) else { return nil }
      return page
    }

    var body: some View {
      NavigationStack {
        Form {
          Section {
            TextField("页码（1 - \(max(vm.pageCount, 1))）", text: $text)
              .keyboardType(.numberPad)
              .focused($focused)
              .onAppear { focused = true }
          } footer: {
            Text("当前第 \(vm.page + 1) 页")
          }
        }
        .yuduPage()
        .navigationTitle("跳转到指定页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("前往") {
              if let validPage { vm.setPage(validPage - 1) }
              dismiss()
            }
            .disabled(validPage == nil)
          }
        }
      }
      .preferredColorScheme(.dark)
      .presentationDetents([.height(260)])
    }
  }

  // MARK: - 目录

  private struct TOCSheet: View {
    let series: SeriesEntity
    let vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
      NavigationStack {
        List {
          ForEach(vm.chapters) { chapter in
            Button {
              dismiss()
              Task { await vm.jumpToChapter(chapter) }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(chapter.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  if chapter.id == vm.current?.id {
                    Text("正在读")
                      .font(.caption2)
                      .foregroundStyle(YuduTheme.accent)
                  }
                }
                Spacer()
                statusIcon(for: chapter)
              }
            }
            .listRowBackground(
              chapter.id == vm.current?.id ? YuduTheme.accent.opacity(0.1) : YuduTheme.surface
            )
          }
        }
        .yuduPage()
        .navigationTitle("章节目录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("关闭") { dismiss() }
          }
        }
      }
      .preferredColorScheme(.dark)
      .presentationDragIndicator(.visible)
    }

    private var entitiesByPath: [String: ChapterEntity] {
      Dictionary(series.chapters.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @ViewBuilder
    private func statusIcon(for chapter: ChapterRef) -> some View {
      let entity = entitiesByPath[chapter.path]
      if entity?.progress?.completed == true {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else if let p = entity?.progress {
        Text("第 \(min(p.page + 1, max(chapter.pageCount, 1))) 页")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}
