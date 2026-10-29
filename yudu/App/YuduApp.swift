import SwiftUI
import SwiftData

@main
struct YuduApp: App {
  let container: ModelContainer
  /// 数据库损坏并降级时给用户的提示；nil 表示正常。
  let storageNotice: String?
  @State private var router = AppRouter()
  @State private var libraryService: LibraryService

  init() {
    let (madeContainer, notice) = Self.makeContainer()
    container = madeContainer
    storageNotice = notice
    _libraryService = State(initialValue: LibraryService(container: madeContainer))
  }

  var body: some Scene {
    WindowGroup {
      RootView(storageNotice: storageNotice)
        .modelContainer(container)
        .environment(router)
        .environment(libraryService)
        .tint(YuduTheme.accent)
    }
  }

  /// 数据库打不开时不能直接崩溃（否则每次启动都闪退）。
  /// 先把疑似损坏的存储挪去备份再重建；仍失败则退到内存库，保证 App 可用。
  private static func makeContainer() -> (ModelContainer, String?) {
    do {
      return (
        try ModelContainer(
          for: LibraryEntity.self, SeriesEntity.self, ChapterEntity.self,
          ProgressEntity.self, ReadingLogEntity.self
        ),
        nil
      )
    } catch {
      let fm = FileManager.default
      if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
        let backup = support
          .appendingPathComponent("Yudu", isDirectory: true)
          .appendingPathComponent("corrupt-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for name in ["default.store", "default.store-shm", "default.store-wal"] {
          let source = support.appendingPathComponent(name)
          if fm.fileExists(atPath: source.path) {
            try? fm.moveItem(at: source, to: backup.appendingPathComponent(name))
          }
        }
        if let rebuilt = try? ModelContainer(
          for: LibraryEntity.self, SeriesEntity.self, ChapterEntity.self,
          ProgressEntity.self, ReadingLogEntity.self
        ) {
          return (rebuilt, "本地数据库损坏，已自动重建；旧数据备份在 App 沙盒内。")
        }
      }
      let inMemory = ModelConfiguration(isStoredInMemoryOnly: true)
      if let fallback = try? ModelContainer(
        for: LibraryEntity.self, SeriesEntity.self, ChapterEntity.self,
        ProgressEntity.self, ReadingLogEntity.self,
        configurations: inMemory
      ) {
        return (fallback, "本地数据库无法打开，本次运行使用临时存储；请重启设备后重试。")
      }
      fatalError("数据库初始化失败：\(error)")
    }
  }
}
