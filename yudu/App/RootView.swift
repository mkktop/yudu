import SwiftUI
import SwiftData

struct RootView: View {
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.dark.rawValue

  @State private var didLaunchRescan = false

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
    .task {
      guard !didLaunchRescan else { return }
      didLaunchRescan = true
      await libraryService.rescanOnLaunch()
      SelfTest.maybeRun(router: router, libraryService: libraryService)
    }
  }
}
