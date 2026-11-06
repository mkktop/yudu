import SwiftUI

/// 「选择目录结构」底部面板：导入含子文件夹的目录时让用户确认形态。
/// 形状相似的结构（「作品/话」与「库/作品」）无法可靠区分，交给用户选择而不是猜测；
/// 选错也不要紧，之后可在书库行菜单里改。
struct LibraryScanLayoutPicker: View {
  let folderName: String
  let onPick: (LibraryScanLayout) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 14) {
      Text(folderName)
        .font(.caption.weight(.semibold))
        .foregroundStyle(YuduTheme.muted)
        .padding(.top, 6)
      VStack(alignment: .leading, spacing: 10) {
        option(
          title: "多部漫画",
          subtitle: "每个子文件夹是一部作品（常见库结构，默认）",
          layout: .multi
        )
        option(
          title: "单部作品",
          subtitle: "整个文件夹是一部漫画，子文件夹/压缩包都是话",
          layout: .single
        )
      }
      Button {
        dismiss()
      } label: {
        Text("取消")
          .font(.subheadline.weight(.medium))
          .foregroundStyle(YuduTheme.text)
          .frame(maxWidth: .infinity, minHeight: 52)
          .background(YuduTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 20)
    .padding(.top, 10)
    .padding(.bottom, 8)
    .presentationDetents([.height(310)])
    .presentationDragIndicator(.visible)
    .presentationBackground(YuduTheme.surface)
  }

  private func option(title: String, subtitle: String, layout: LibraryScanLayout) -> some View {
    Button {
      onPick(layout)
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(YuduTheme.text)
        Text(subtitle).font(.caption).foregroundStyle(YuduTheme.muted)
      }
      .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      .padding(.horizontal, 16)
      .background(YuduTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain)
  }
}
