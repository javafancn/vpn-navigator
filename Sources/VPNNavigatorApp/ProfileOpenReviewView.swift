import SwiftUI
import VPNNavigatorCore

struct ProfileOpenReviewView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("导入连接配置")).font(.system(size: 24, weight: .bold))
            Text(L10n.format("已收到 {0} 个配置，确认后保存到此 Mac。", [String(describing: model.incomingProfiles.urls.count)]))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.incomingProfiles.filenames.enumerated()), id: \.offset) { _, name in
                        Label(name, systemImage: "doc.text")
                            .font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        Divider().opacity(0.2)
                    }
                }
            }.glassCard(cornerRadius: 14)
            VStack(alignment: .leading, spacing: 5) {
                if model.incomingProfiles.unsupportedCount > 0 {
                    Text(L10n.format("{0} 项未加入：仅支持本机 .ovpn 文件。", [String(describing: model.incomingProfiles.unsupportedCount)]))
                }
                if model.incomingProfiles.duplicateCount > 0 {
                    Text(L10n.format("已忽略 {0} 个重复文件。", [String(describing: model.incomingProfiles.duplicateCount)]))
                }
                if model.incomingProfiles.overflowCount > 0 {
                    Text(L10n.format("{0} 项超出上限，请分批重新打开或拖入（最多 100 个）。", [String(describing: model.incomingProfiles.overflowCount)]))
                }
                if model.incomingProfiles.unreadableCount > 0 {
                    Text(L10n.format("{0} 项未能取得文件位置，请从 Finder 重试。", [String(describing: model.incomingProfiles.unreadableCount)]))
                }
                Text(L10n.text("只导入所列文件；可在下一步查看结果。配置可能包含私钥，请确认文件来源。"))
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("取消")) { model.clearImportReport() }
                    .buttonStyle(ReferenceSecondaryButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.format("导入 {0} 个配置", [String(describing: model.incomingProfiles.urls.count)])) {
                    Task { await model.confirmIncomingProfiles() }
                }.buttonStyle(ReferencePrimaryButton()).disabled(!model.canConfirmIncomingProfiles)
            }
        }.padding(24).frame(width: 620, height: 450).background(GlassAtmosphere())
            .interactiveDismissDisabled()
    }
}
