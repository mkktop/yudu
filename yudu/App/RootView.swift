import SwiftUI
import SwiftData

struct RootView: View {
  var storageNotice: String? = nil
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.dark.rawValue

  @State private var didStart = false
  @State private var showStorageNotice = false

  private var appearance: AppearanceMode {
    AppearanceMode(rawValue: appearanceRaw) ?? .system
  }

  var body: some View {
    TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
      BookshelfView()
        .tabItem { Label("书架", systemImage: "books.vertical") }
        .tag(AppTab.bookshelf)
      LibraryView()
        .tabItem { Label("书库", systemImage: "square.stack.3d.up") }
        .tag(AppTab.library)
      StatsView()
        .tabItem { Label("统计", systemImage: "chart.bar.xaxis") }
        .tag(AppTab.stats)
      SettingsView()
        .tabItem { Label("设置", systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .tint(YuduTheme.accent)
    .toolbarBackground(YuduTheme.surface, for: .tabBar)
    .preferredColorScheme(appearance.scheme)
    .sheet(isPresented: Binding(get: { router.showImport }, set: { router.showImport = $0 })) {
      ImportSheet()
    }
    .alert("存储异常", isPresented: $showStorageNotice) {
      Button("好", role: .cancel) {}
    } message: {
      Text(storageNotice ?? "")
    }
    .task {
      guard !didStart else { return }
      didStart = true
      if storageNotice != nil { showStorageNotice = true }
      #if DEBUG
      SelfTest.maybeRun(router: router, libraryService: libraryService)
      #endif
    }
  }
}
