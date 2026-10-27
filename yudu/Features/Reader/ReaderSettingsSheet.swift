import SwiftUI

struct ReaderSettingsSheet: View {
  let vm: ReaderViewModel
  @Binding var eyeCare: EyeCare
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        if !vm.isPDF {
          Section("此漫画的阅读方式") {
            Picker("阅读模式", selection: Binding(get: { vm.prefs.mode }, set: { vm.setMode($0) })) {
              ForEach(ReaderMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
            Picker("画面适配", selection: Binding(get: { vm.prefs.fit }, set: { vm.setFit($0) })) {
              ForEach(ReaderFit.allCases) { Text($0.label).tag($0) }
            }
            if vm.effectiveMode == .single {
              Toggle("从右向左翻页（日漫）", isOn: Binding(get: { vm.prefs.rtl }, set: { vm.setRTL($0) }))
            }
          }.listRowBackground(YuduTheme.surface)
        }
        Section {
          VStack(alignment: .leading) {
            Label("亮度 \(Int(eyeCare.brightness * 100))%", systemImage: "sun.max")
            Slider(value: $eyeCare.brightness, in: 0.4...1).accessibilityLabel("阅读亮度")
          }
          VStack(alignment: .leading) {
            Label("暖色 \(Int(eyeCare.warmth / 0.6 * 100))%", systemImage: "moon.stars")
            Slider(value: $eyeCare.warmth, in: 0...0.6).accessibilityLabel("暖色滤镜")
          }
          Toggle("夜间自动暖色", isOn: $eyeCare.scheduleEnabled)
        } header: { Text("护眼滤镜") } footer: { Text("滤镜仅影响漫画画面。夜间时段为 20:00 – 次日 07:00。") }
          .listRowBackground(YuduTheme.surface)
      }
      .yuduPage()
      .navigationTitle("阅读设置")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
      }
    }
    .tint(YuduTheme.accent)
    .preferredColorScheme(.dark)
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .onChange(of: eyeCare) { _, value in value.save() }
  }
}
