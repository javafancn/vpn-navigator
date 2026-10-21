import SwiftUI
import VPNNavigatorCore

struct ProfileImportReportView: View {
    @EnvironmentObject private var model: AppModel
    private var completed: Int { model.importResults.filter { item in
        switch item.status { case .waiting, .importing: return false; default: return true }
    }.count }
    private var imported: Int { model.importResults.filter { if case .imported = $0.status { return true }; return false }.count }
    private var failed: Int { model.importResults.filter { if case .failed = $0.status { return true }; return false }.count }
    private var cancelled: Int { model.importResults.filter { $0.status == .cancelled }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.profileImportInProgress ? "正在导入配置" : "配置导入结果")
                .font(.system(size: 24, weight: .bold))
            Text("成功 \(imported) · 失败 \(failed) · 取消 \(cancelled)")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            if model.profileImportInProgress {
                ProgressView(value: Double(completed), total: Double(max(1, model.importResults.count)))
                    .tint(GlassPalette.blue)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.importResults) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbol(item.status)).foregroundStyle(color(item.status))
                                .frame(width: 20).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.filename).font(.system(size: 14, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(detail(item.status)).font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        if item.id != model.importResults.last?.id { Divider().opacity(0.2) }
                    }
                }
            }.glassCard(cornerRadius: 14)
            HStack {
                if model.profileImportInProgress {
                    Text(model.importCancellationRequested ? "等待当前文件处理完成…" : "取消后，当前文件会完成，已导入配置会保留。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消剩余导入") { model.cancelProfileImport() }
                        .buttonStyle(ReferenceSecondaryButton()).disabled(model.importCancellationRequested)
                } else {
                    Text("成功导入的配置已保存到本机。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") { model.clearImportReport() }.buttonStyle(ReferencePrimaryButton())
                }
            }
        }.padding(24).frame(width: 620, height: 450).background(GlassAtmosphere())
            .interactiveDismissDisabled(model.profileImportInProgress)
            .onDisappear { model.clearImportReport() }
    }
    private func detail(_ status: ProfileImportResult.Status) -> String {
        switch status {
        case .waiting: return "等待导入"
        case .importing: return "正在读取并保存"
        case .imported: return "导入成功"
        case .failed(let failure): return failure.summary
        case .cancelled: return "已取消，未读取此文件"
        }
    }
    private func symbol(_ status: ProfileImportResult.Status) -> String {
        switch status {
        case .imported: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "minus.circle"
        case .importing: return "arrow.down.circle"
        case .waiting: return "clock"
        }
    }
    private func color(_ status: ProfileImportResult.Status) -> Color {
        switch status { case .imported: return .green; case .failed: return .orange; default: return .secondary }
    }
}
