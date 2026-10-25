import SwiftUI
import SwiftData

struct RootView: View {
  @Environment(AppRouter.self) private var router
  @Environment(LibraryService.self) private var libraryService
  @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

  @State private var didLaunchRescan = false

  private var appearance: AppearanceMode {
    AppearanceMode(rawValue: appearanceRaw) ?? .system
  }

  var body: some View {
    TabView(selection: Binding(get: { router.tab }, set: { router.tab = $0 })) {
      BookshelfView()
        .tabItem { Label("书架", systemImage: "books.vertical") }
        .tag(AppTab.bookshelf)
      StatsView()
        .tabItem { Label("统计", systemImage: "chart.bar.xaxis") }
        .tag(AppTab.stats)
      SettingsView()
        .tabItem { Label("设置", systemImage: "gearshape") }
        .tag(AppTab.settings)
    }
    .preferredColorScheme(appearance.scheme)
    .task {
      guard !didLaunchRescan else { return }
      didLaunchRescan = true
      await libraryService.rescanOnLaunch()
      SelfTest.maybeRun(router: router, libraryService: libraryService)
    }
  }
}
