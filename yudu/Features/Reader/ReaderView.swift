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

  @State private var vm: ReaderViewModel?
  @State private var eyeCare = EyeCare.load()
  @State private var showJumpSheet = false
  @State private var showTOC = false

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
    .toolbarBackground(.hidden, for: .tabBar)
    .task(id: token) {
      vm?.stop()
      let model = ReaderViewModel(
        series: series, startChapter: startChapter, context: context, libraryService: libraryService
      )
      vm = model
      model.start()
    }
    .onDisappear {
      vm?.stop()
    }
    .sheet(isPresented: $showJumpSheet) {
      if let vm {
        JumpSheet(vm: vm)
      }
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
        Button("返回") { dismiss() }
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
        onPageChanged: { vm.setPage($0) },
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
    let warmth = eyeCare.effectiveWarmth
    ZStack {
      if eyeCare.brightness < 1.0 {
        Color.black.opacity(1.0 - eyeCare.brightness)
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
    if vm.showDirectionHint {
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

  @ViewBuilder
  private func chrome(_ vm: ReaderViewModel) -> some View {
    VStack {
      if vm.chromeVisible {
        topBar(vm)
          .transition(.move(edge: .top).combined(with: .opacity))
        Spacer()
        bottomBar(vm)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      } else {
        Spacer()
      }
    }
    .animation(.easeInOut(duration: 0.22), value: vm.chromeVisible)
  }

  private func topBar(_ vm: ReaderViewModel) -> some View {
    HStack(spacing: 12) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.down")
          .font(.body.weight(.semibold))
          .frame(width: 34, height: 34)
      }
      .tint(.white)

      VStack(alignment: .leading, spacing: 1) {
        Text(vm.current?.seriesTitle ?? series.title)
          .font(.footnote)
          .foregroundStyle(.white.opacity(0.6))
          .lineLimit(1)
        Text(vm.current?.title ?? "")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(.white)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button {
        showJumpSheet = true
      } label: {
        Text(pageChip(vm))
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(.white.opacity(0.14), in: Capsule())
      }

      Button {
        showTOC = true
      } label: {
        Image(systemName: "list.bullet")
          .font(.body)
          .frame(width: 34, height: 34)
      }
      .tint(.white)
    }
    .padding(.horizontal, 12)
    .padding(.top, 6)
    .padding(.bottom, 10)
    .background(
      LinearGradient(colors: [.black.opacity(0.75), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .top)
    )
  }

  private func pageChip(_ vm: ReaderViewModel) -> String {
    if vm.pageCount > 0 {
      "\(vm.page + 1) / \(vm.pageCount)"
    } else {
      "\(vm.page + 1) / ?"
    }
  }

  private func bottomBar(_ vm: ReaderViewModel) -> some View {
    HStack(spacing: 14) {
      Button {
        Task { await vm.goToChapter(offset: -1, landing: -1) }
      } label: {
        Image(systemName: "chevron.left.circle")
          .font(.title3)
      }
      .tint(.white)
      .disabled(vm.prevChapter == nil)
      .opacity(vm.prevChapter == nil ? 0.35 : 1)

      Group {
        if vm.isPDF {
          Text("PDF · 连续阅读")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
        } else {
          Picker("模式", selection: Binding(
            get: { vm.prefs.mode },
            set: { vm.setMode($0) }
          )) {
            Text("单页").tag(ReaderMode.single)
            Text("条漫").tag(ReaderMode.webtoon)
          }
          .pickerStyle(.segmented)
          .frame(width: 132)
        }
      }
      .frame(maxWidth: .infinity)

      Button {
        Task { await vm.goToChapter(offset: 1, landing: 0) }
      } label: {
        Image(systemName: "chevron.right.circle")
          .font(.title3)
      }
      .tint(.white)
      .disabled(vm.nextChapter == nil)
      .opacity(vm.nextChapter == nil ? 0.35 : 1)

      Divider()
        .frame(height: 20)

      Button {
        vm.setRTL(!vm.prefs.rtl)
      } label: {
        Text(vm.prefs.rtl ? "日漫" : "西漫")
          .font(.footnote.weight(.medium))
      }
      .tint(.white)

      Button {
        vm.setFit(vm.prefs.fit == .width ? .height : .width)
      } label: {
        Text(vm.prefs.fit.label)
          .font(.footnote.weight(.medium))
      }
      .tint(.white)
    }
    .padding(.horizontal, 14)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .background(
      LinearGradient(colors: [.black.opacity(0), .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
        .ignoresSafeArea(edges: .bottom)
    )
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

  private struct JumpSheet: View {
    let vm: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

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
        .navigationTitle("跳页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("前往") {
              if let n = Int(text.trimmingCharacters(in: .whitespaces)), n >= 1 {
                vm.setPage(n - 1)
              }
              dismiss()
            }
          }
        }
      }
      .presentationDetents([.height(180)])
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
                      .foregroundStyle(.cinnabar)
                  }
                }
                Spacer()
                statusIcon(for: chapter)
              }
            }
            .listRowBackground(
              chapter.id == vm.current?.id ? Color.cinnabar.opacity(0.1) : Color.clear
            )
          }
        }
        .navigationTitle("目录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("关闭") { dismiss() }
          }
        }
      }
    }

    @ViewBuilder
    private func statusIcon(for chapter: ChapterRef) -> some View {
      let entity = series.chapters.first { $0.path == chapter.path }
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
