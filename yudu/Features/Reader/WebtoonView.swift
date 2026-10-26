import SwiftUI

/// 视口内各页 frame 上报（条漫当前页 = 包含视口中线的页）
struct VisibleFramesKey: PreferenceKey {
  static var defaultValue: [Int: CGRect] = [:]

  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

/// 条漫 / PDF 竖滚阅读
struct WebtoonView: View {
  @Bindable var vm: ReaderViewModel

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(0..<max(vm.pageCount, 1), id: \.self) { index in
              WebtoonPageItem(vm: vm, index: index, width: width)
                .id("p\(index)")
            }
            nextChapterCard
          }
          .padding(.bottom, 40)
        }
        .coordinateSpace(name: "webtoonScroll")
        .onPreferenceChange(VisibleFramesKey.self) { frames in
          guard !frames.isEmpty else { return }
          vm.reportVisibleFrames(frames, viewportHeight: geo.size.height)
        }
        .onChange(of: vm.dimsReadyThrough) {
          restoreScrollIfNeeded(proxy: proxy)
        }
        .onAppear {
          restoreScrollIfNeeded(proxy: proxy)
        }
      }
    }
    .background(Color.black)
    .overlay {
      if vm.restoringScroll {
        ProgressView("正在恢复进度…")
          .tint(.white)
          .foregroundStyle(.white)
          .padding(16)
          .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
      }
    }
  }

  @ViewBuilder
  private var nextChapterCard: some View {
    if let next = vm.nextChapter {
      Button {
        Task { await vm.goToChapter(offset: 1, landing: 0) }
      } label: {
        HStack {
          Text("下一话 · \(next.title)")
            .font(.callout.weight(.medium))
          Image(systemName: "arrow.down.circle")
        }
        .foregroundStyle(.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color.white.opacity(0.08))
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    } else {
      Text("已到最后一话")
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.4))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }
  }

  private func restoreScrollIfNeeded(proxy: ScrollViewProxy) {
    guard vm.restoringScroll, vm.dimsReadyThrough >= vm.page else { return }
    proxy.scrollTo("p\(vm.page)", anchor: .top)
    vm.finishRestoringScroll()
  }
}

private struct WebtoonPageItem: View {
  let vm: ReaderViewModel
  let index: Int
  let width: CGFloat

  @State private var image: UIImage?

  private var aspect: CGFloat {
    if let dims = vm.dims[index], dims.width > 0 {
      return dims.height / dims.width
    }
    return 1.4
  }

  var body: some View {
    let height = width * aspect
    ZStack {
      Color.black
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        ProgressView()
          .tint(.white.opacity(0.5))
      }
    }
    .frame(width: width, height: height)
    .clipped()
    .task(id: "\(vm.sourceID)#\(index)") {
      guard vm.pageCount > 0, let source = vm.source else { return }
      let sid = vm.sourceID
      image = await PageCache.shared.image(sourceID: sid, index: index, maxPixel: 2048) {
        source.pageImage(at: index, maxPixel: 2048)
      }
    }
    .background(
      GeometryReader { geo in
        Color.clear.preference(
          key: VisibleFramesKey.self,
          value: [index: geo.frame(in: .named("webtoonScroll"))]
        )
      }
    )
    .onTapGesture {
      vm.toggleChrome()
    }
  }
}
