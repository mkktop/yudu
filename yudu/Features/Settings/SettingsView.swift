import SwiftUI

struct SettingsView: View {
  @Environment(LibraryService.self) private var libraryService
  @Environment(AppRouter.self) private var router
  @AppStorage("appearanceMode") private var appearanceRaw = AppearanceMode.dark.rawValue
  @AppStorage("dailyReadingGoal") private var dailyGoal = 30
  @State private var defaults = ReaderDefaults.load()
  @State private var eyeCare = EyeCare.load()
  @State private var showCacheClear = false
  @State private var cacheBytes: Int64 = 0
  @State private var cacheLimit = WebDAVCache.shared.capBytes

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 26) {
          HStack(spacing: 16) {
            OrbitalEmblem(size: 62)
            VStack(alignment: .leading, spacing: 6) {
              Text("雨读 YUDU").font(.title3.weight(.semibold))
              Text("让阅读，进入你的轨道。")
                .font(.caption).foregroundStyle(YuduTheme.muted)
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(20).yuduPanel(accent: YuduTheme.accent)
          settingsGroup("界面外观", eyebrow: "APPEARANCE") {
            Picker("外观模式", selection: $appearanceRaw) {
              ForEach(AppearanceMode.allCases) { Text($0.label).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            Text("深空与晨光，两种阅读氛围。跟随系统可自动切换。")
              .font(.caption).foregroundStyle(YuduTheme.muted)
          }
          settingsGroup("阅读偏好", eyebrow: "READING PREFERENCES") {
            Picker("默认阅读模式", selection: Binding(get: { defaults.mode }, set: { defaults.mode = $0; defaults.save() })) {
              ForEach(ReaderMode.allCases) { Text($0.label).tag($0) }
            }
            Divider().overlay(YuduTheme.line)
            Picker("画面适配", selection: Binding(get: { defaults.fit }, set: { defaults.fit = $0; defaults.save() })) {
              ForEach(ReaderFit.allCases) { Text($0.label).tag($0) }
            }
            Divider().overlay(YuduTheme.line)
            Toggle("从右向左翻页", isOn: Binding(get: { defaults.rtl }, set: { defaults.rtl = $0; defaults.save() }))
            Text("适用于日漫。每部漫画在阅读器中修改的偏好会单独记住。")
              .font(.caption).foregroundStyle(YuduTheme.muted)
          }
          settingsGroup("护眼与亮度", eyebrow: "EYE COMFORT") {
            comfortSlider(title: "阅读亮度", value: Binding(get: { eyeCare.brightness }, set: { eyeCare.brightness = $0; eyeCare.save() }), range: 0.4...1, percent: Int(eyeCare.brightness * 100), icon: "sun.max")
            Divider().overlay(YuduTheme.line)
            comfortSlider(title: "暖色滤镜", value: Binding(get: { eyeCare.warmth }, set: { eyeCare.warmth = $0; eyeCare.save() }), range: 0...0.6, percent: Int(eyeCare.warmth / 0.6 * 100), icon: "moon.stars")
            Toggle("夜间自动启用暖色", isOn: Binding(get: { eyeCare.scheduleEnabled }, set: { eyeCare.scheduleEnabled = $0; eyeCare.save() }))
            Text("20:00 – 次日 07:00 生效；护眼滤镜只影响漫画画面。")
              .font(.caption).foregroundStyle(YuduTheme.muted)
          }
          settingsGroup("每日阅读目标", eyebrow: "DAILY GOAL") {
            Stepper(value: $dailyGoal, in: 5...200, step: 5) {
              HStack {
                Text("每天")
                Text("\(dailyGoal) 页").monospacedDigit().foregroundStyle(YuduTheme.accent)
              }
            }
            Text("目标会显示在统计页。按翻页进度统计，手动标记已读不计入。")
              .font(.caption).foregroundStyle(YuduTheme.muted)
          }
          settingsGroup("离线缓存", eyebrow: "OFFLINE STORAGE") {
            HStack {
              Label("已用空间", systemImage: "internaldrive")
              Spacer()
              Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                .font(.subheadline.monospacedDigit()).foregroundStyle(YuduTheme.accent)
            }
            if cacheLimit > 0 {
              ProgressView(value: Double(min(cacheBytes, cacheLimit)), total: Double(cacheLimit)).tint(YuduTheme.accent)
            }
            Picker("缓存容量上限", selection: $cacheLimit) {
              Text("不自动缓存").tag(Int64(0))
              Text("1 GB").tag(Int64(1 << 30))
              Text("2 GB").tag(Int64(2 << 30))
              Text("4 GB").tag(Int64(4 << 30))
              Text("8 GB").tag(Int64(8 << 30))
            }
            .onChange(of: cacheLimit) { _, value in
              WebDAVCache.shared.capBytes = value
              cacheBytes = WebDAVCache.shared.usageBytes()
            }
            Text(cacheLimit == 0
              ? "不自动写入缓存。手动离线仍会保留文件；超过 600 MB 的大包可能临时写盘。"
              : "超出上限时清理最久未看的章节。手动离线的漫画受保护，可能超出设定容量。")
              .font(.caption).foregroundStyle(YuduTheme.muted)
            Button(role: .destructive) { showCacheClear = true } label: {
              Label("清理全部缓存", systemImage: "trash").frame(minHeight: 44)
            }.disabled(cacheBytes == 0 || !libraryService.prefetchProgress.isEmpty)
            if !libraryService.prefetchProgress.isEmpty {
              Text("有漫画正在缓存，取消任务后可清理空间。")
                .font(.caption).foregroundStyle(YuduTheme.warning)
            }
          }
          Button { router.tab = .library } label: {
            HStack {
              Label("管理本地与云端书库", systemImage: "square.stack.3d.up")
              Spacer()
              Image(systemName: "arrow.up.right")
            }.font(.subheadline).padding(20).yuduPanel()
          }.buttonStyle(.plain).foregroundStyle(YuduTheme.accent)
          VStack(spacing: 6) {
            Text("YUDU · ORBITAL EDITION")
              .font(.system(size: 10, design: .monospaced)).tracking(2)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
              .font(.caption2)
          }.foregroundStyle(YuduTheme.muted).frame(maxWidth: .infinity).padding(.bottom, 10)
        }
        .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
      }
      .yuduPage()
      .navigationTitle("设置")
      .navigationBarTitleDisplayMode(.inline)
      .onAppear {
        defaults = ReaderDefaults.load()
        eyeCare = EyeCare.load()
        cacheBytes = WebDAVCache.shared.usageBytes()
      }
      .confirmationDialog("清理全部离线缓存？", isPresented: $showCacheClear, titleVisibility: .visible) {
        Button("清理缓存", role: .destructive) {
          WebDAVCache.shared.clearAll()
          cacheBytes = WebDAVCache.shared.usageBytes()
        }
        Button("取消", role: .cancel) {}
      } message: { Text("包括手动离线的漫画。云端文件和阅读进度保留，下次阅读需要重新下载。") }
    }
  }

  private func settingsGroup<Content: View>(_ title: String, eyebrow: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      SectionHeading(title: title, eyebrow: eyebrow)
      VStack(alignment: .leading, spacing: 16, content: content)
        .font(.subheadline).padding(18).yuduPanel()
    }
  }

  private func comfortSlider(title: String, value: Binding<Double>, range: ClosedRange<Double>, percent: Int, icon: String) -> some View {
    VStack(spacing: 9) {
      HStack {
        Label(title, systemImage: icon)
        Spacer()
        Text("\(percent)%").font(.caption.monospacedDigit()).foregroundStyle(YuduTheme.accent)
      }
      Slider(value: value, in: range).accessibilityLabel(title)
    }
  }
}
