import SwiftUI
import VPNNavigatorCore

struct ProfileIndexRecoveryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.text("配置列表恢复"), systemImage: "externaldrive.badge.timemachine")
                .font(.system(size: 23, weight: .bold))
            Text(model.profileIndexIssue ?? L10n.text("当前配置列表可正常读取。"))
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Text(model.profileIndexBackupStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let preview = model.profileIndexRecovery {
                Text(L10n.text("备份时间：") + preview.savedAt.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute()))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(L10n.format("将恢复 {0} 个配置的名称、分组、收藏和默认路由策略。", [String(describing: preview.profiles.count)]))
                    .font(.system(size: 14, weight: .medium))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(preview.profiles) { profile in
                            HStack {
                                Image(systemName: profile.isFavorite ? "star.fill" : "doc.text")
                                    .foregroundStyle(profile.isFavorite ? Color.orange : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(profile.group + " · " + profile.mode.title)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                    }.padding(12)
                }.frame(height: min(220, CGFloat(max(1, preview.profiles.count)) * 52 + 24))
                    .glassCard(cornerRadius: 12)
                Text(L10n.text("恢复会保留故障索引；配置正文、历史版本和 Keychain 凭据继续使用本机原件。请先断开 VPN 并等待其它操作结束。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem = model.profileIndexRecoveryProblem {
                Text(problem).font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.text("重新检查")) { Task { await model.inspectProfileIndex() } }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(model.profileTransferInProgress || model.busy)
                Spacer()
                Button(L10n.text("关闭")) { dismiss() }.buttonStyle(ReferenceSecondaryButton())
                    .disabled(model.profileIndexRecoveryInProgress)
                if model.profileIndexIssue == nil {
                    Button(L10n.text("更新列表备份")) { Task { await model.refreshProfileIndexBackup() } }
                        .buttonStyle(ReferencePrimaryButton()).disabled(!model.canManageProfileIndex)
                }
                if model.profileIndexIssue != nil {
                    Button(model.profileIndexRecoveryInProgress ? L10n.text("恢复中…") : L10n.text("确认恢复列表")) {
                        Task { await model.recoverProfileIndex() }
                    }.buttonStyle(ReferencePrimaryButton()).disabled(!model.canRecoverProfileIndex)
                }
            }
        }.padding(24).frame(width: 580).background(GlassAtmosphere())
            .interactiveDismissDisabled(model.profileIndexRecoveryInProgress)
    }
}
