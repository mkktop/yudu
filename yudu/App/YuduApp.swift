import SwiftUI
import SwiftData

@main
struct YuduApp: App {
  let container: ModelContainer
  @State private var router = AppRouter()
  @State private var libraryService: LibraryService

  init() {
    do {
      container = try ModelContainer(
        for: LibraryEntity.self, SeriesEntity.self, ChapterEntity.self,
        ProgressEntity.self, SeriesPrefsEntity.self, ReadingLogEntity.self
      )
    } catch {
      fatalError("数据库初始化失败：\(error)")
    }
    _libraryService = State(initialValue: LibraryService(container: container))
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .modelContainer(container)
        .environment(router)
        .environment(libraryService)
        .tint(.cinnabar)
    }
  }
}
