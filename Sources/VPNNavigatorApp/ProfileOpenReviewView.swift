import SwiftUI
import VPNNavigatorCore

struct ProfileOpenReviewView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导入连接配置").font(.system(size: 24, weight: .bold))
            Text("已收到 \(model.incomingProfiles.urls.count) 个配置，确认后保存到此 Mac。")
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
                    Text("\(model.incomingProfiles.unsupportedCount) 项未加入：仅支持本机 .ovpn 文件。")
                }
                if model.incomingProfiles.duplicateCount > 0 {
                    Text("已忽略 \(model.incomingProfiles.duplicateCount) 个重复文件。")
                }
                if model.incomingProfiles.overflowCount > 0 {
                    Text("\(model.incomingProfiles.overflowCount) 项超出上限，请分批重新打开或拖入（最多 100 个）。")
                }
                if model.incomingProfiles.unreadableCount > 0 {
                    Text("\(model.incomingProfiles.unreadableCount) 项未能取得文件位置，请从 Finder 重试。")
                }
                Text("只导入所列文件；可在下一步查看结果。配置可能包含私钥，请确认文件来源。")
            }.font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("取消") { model.clearImportReport() }
                    .buttonStyle(ReferenceSecondaryButton()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("导入 \(model.incomingProfiles.urls.count) 个配置") {
                    Task { await model.confirmIncomingProfiles() }
                }.buttonStyle(ReferencePrimaryButton()).disabled(!model.canConfirmIncomingProfiles)
            }
        }.padding(24).frame(width: 620, height: 450).background(GlassAtmosphere())
            .interactiveDismissDisabled()
    }
}
