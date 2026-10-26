import SwiftUI
import SwiftData

struct SettingsView: View {
  @Environment(\.modelContext) private var context
  @Environment(LibraryService.self) private var libraryService

  @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.system.rawValue

  @State private var defaults = ReaderDefaults.load()
  @State private var eyeCare = EyeCare.load()
  @State private var showRemoveConfirm: LibraryEntity?
  @State private var showCacheClear = false
  @State private var cacheUsage = 0

  var body: some View {
    NavigationStack {
      Form {
        appearanceSection
        readerSection
        eyeCareSection
        librarySection
        webdavCacheSection
        aboutSection
      }
      .navigationTitle("设置")
    }
  }

  // MARK: - 外观

  private var appearanceSection: some View {
    Section("外观") {
      Picker("模式", selection: $appearanceRaw) {
        ForEach(AppearanceMode.allCases) { mode in
          Text(mode.label).tag(mode.rawValue)
        }
      }
      .pickerStyle(.segmented)
    }
  }

  // MARK: - 阅读默认

  private var readerSection: some View {
    Section {
      Picker("默认模式", selection: Binding(
        get: { defaults.mode },
        set: { defaults.mode = $0; defaults.save() }
      )) {
        ForEach(ReaderMode.allCases) { mode in
          Text(mode.label).tag(mode)
        }
      }
      Picker("默认适配", selection: Binding(
        get: { defaults.fit },
        set: { defaults.fit = $0; defaults.save() }
      )) {
        ForEach(ReaderFit.allCases) { fit in
          Text(fit.label).tag(fit)
        }
      }
      Toggle("默认从右往左（日漫）", isOn: Binding(
        get: { defaults.rtl },
        set: { defaults.rtl = $0; defaults.save() }
      ))
    } header: {
      Text("阅读")
    } footer: {
      Text("只对没有单独调过设置的漫画生效；阅读器里改的会按书记住。")
    }
  }

  // MARK: - 护眼

  private var eyeCareSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text("亮度 \(Int(eyeCare.brightness * 100))%")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Slider(value: Binding(
          get: { eyeCare.brightness },
          set: { eyeCare.brightness = $0; eyeCare.save() }
        ), in: 0.4...1.0)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("暖色 \(Int(eyeCare.warmth / 0.6 * 100))%")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Slider(value: Binding(
          get: { eyeCare.warmth },
          set: { eyeCare.warmth = $0; eyeCare.save() }
        ), in: 0...0.6)
      }
      Toggle("夜间时段自动暖色（20:00 – 07:00）", isOn: Binding(
        get: { eyeCare.scheduleEnabled },
        set: { eyeCare.scheduleEnabled = $0; eyeCare.save() }
      ))
    } header: {
      Text("护眼")
    } footer: {
      Text("只作用于阅读画面，不影响其他页面。")
    }
  }

  // MARK: - 书库

  private var librarySection: some View {
    Section {
      let libraries = (try? context.fetch(FetchDescriptor<LibraryEntity>())) ?? []
      if libraries.isEmpty {
        Text("还没有书库，去书架右上角 + 导入")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      ForEach(libraries, id: \.persistentModelID) { library in
        HStack {
          VStack(alignment: .leading, spacing: 3) {
            Text(library.name)
              .font(.subheadline)
            Label(
              libraryKindLabel(library),
              systemImage: library.kind == "folder" ? "folder" : (library.kind == "webdav" ? "cloud" : "doc.on.doc")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          Spacer()
          Button("重扫") {
            Task { await libraryService.rescan(library) }
          }
          .font(.footnote)
          .disabled(libraryService.isScanning)
          Button("移除", role: .destructive) {
            showRemoveConfirm = library
          }
          .font(.footnote)
        }
      }
      Button {
        Task { await libraryService.rescanAll() }
      } label: {
        Label("重新扫描全部", systemImage: "arrow.triangle.2.circlepath")
      }
      .disabled(libraryService.isScanning)

      if libraryService.isScanning {
        HStack(spacing: 8) {
          ProgressView()
          Text("扫描中…")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      if !libraryService.lastErrors.isEmpty {
        DisclosureGroup("扫描提示（\(libraryService.lastErrors.count)）") {
          ForEach(libraryService.lastErrors.prefix(10), id: \.self) { error in
            Text(error)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    } header: {
      Text("书库")
    } footer: {
      Text("移除书库只删阅读进度与记录，授权文件夹和原文件不受影响；导入文件库会删除拷贝进来的副本。")
    }
    .confirmationDialog(
      "清理 WebDAV 离线缓存？",
      isPresented: $showCacheClear,
      titleVisibility: .visible
    ) {
      Button("清理", role: .destructive) {
        WebDAVCache.shared.clearAll()
        cacheUsage += 1
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("已离线保护的漫画也会被清掉（云端文件不受影响），下次阅读会重新下载。")
    }
    .confirmationDialog(
      "移除「\(showRemoveConfirm?.name ?? "")」？",
      isPresented: Binding(
        get: { showRemoveConfirm != nil },
        set: { if !$0 { showRemoveConfirm = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("移除", role: .destructive) {
        if let library = showRemoveConfirm {
          libraryService.removeLibrary(library)
        }
        showRemoveConfirm = nil
      }
      Button("取消", role: .cancel) { showRemoveConfirm = nil }
    } message: {
      Text(showRemoveConfirm?.kind == "folder"
        ? "文件夹与漫画文件保留，仅清除本机的进度"
        : "将删除导入的文件副本与全部进度")
    }
  }

  // MARK: - WebDAV 缓存

  private var webdavCacheSection: some View {
    Section {
      let bytes = WebDAVCache.shared.usageBytes()
      LabeledContent("已用缓存", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
      Picker("容量上限", selection: Binding(
        get: { WebDAVCache.shared.capBytes },
        set: { WebDAVCache.shared.capBytes = $0; cacheUsage += 1 }
      )) {
        Text("不缓存").tag(Int64(0))
        Text("1 GB").tag(Int64(1 << 30))
        Text("2 GB").tag(Int64(2 << 30))
        Text("4 GB").tag(Int64(4 << 30))
        Text("8 GB").tag(Int64(8 << 30))
      }
      Button(role: .destructive) {
        showCacheClear = true
      } label: {
        Label("清理全部缓存", systemImage: "trash")
      }
      .disabled(bytes == 0)
    } header: {
      Text("云端离线缓存")
    } footer: {
      Text(WebDAVCache.shared.diskless
        ? "无盘模式：阅读不写硬盘，整包在内存中直接读（超过 600MB 的大包会临时落盘）；手动点“离线缓存整部”仍会写盘。"
        : "看过的章节自动缓存，断网也能翻；超过容量上限按最久未看清理（点过“离线缓存”的漫画受保护）。选“不缓存”可完全不写硬盘。")
    }
  }

  private func libraryKindLabel(_ library: LibraryEntity) -> String {
    switch library.kind {
    case "folder": "授权文件夹 · \(library.series.count) 部"
    case "webdav": "WebDAV · \(library.series.count) 部"
    case "cloud189": "天翼云盘\(library.remoteFamilyId != nil ? "·家庭云" : "") · \(library.series.count) 部"
    default: "导入文件 · \(library.series.count) 部"
    }
  }

  // MARK: - 关于

  private var aboutSection: some View {
    Section("关于") {
      LabeledContent("雨读", value: "iOS 1.0")
      LabeledContent("桌面版", value: "雨读 Yudu")
    }
  }
}
