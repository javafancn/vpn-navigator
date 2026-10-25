import SwiftUI
import UniformTypeIdentifiers
import VPNNavigatorCore

@MainActor
final class ProfileUpdateController: ObservableObject {
    @Published private(set) var preview: ProfileUpdatePreview?
    @Published private(set) var busy = false
    @Published private(set) var problem: String?
    @Published private(set) var status: String?
    @Published var confirmed = false
    @Published var identityConfirmed = false
    @Published var healthConfirmed = false
    private weak var model: AppModel?
    let profileID: UUID
    private var task: Task<Void, Never>?
    init(model: AppModel, id: UUID) { self.model = model; profileID = id }
    var canApply: Bool {
        guard let preview else { return false }
        return !busy && confirmed && preview.contentChanged && (!preview.identityChanged || identityConfirmed) &&
            (preview.health.issues.isEmpty || healthConfirmed) && model?.canUpdateProfile(profileID) == true
    }
    func reset() { guard !busy else { return }; preview = nil; confirmed = false; identityConfirmed = false; healthConfirmed = false; problem = nil; status = nil }
    func cancel() { task?.cancel() }
    func chooseFile() {
        guard !busy else { return }; reset()
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "ovpn")!]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "选择新的 .ovpn；引用的证书与私钥需位于同一目录或其子目录。只预览，确认后才更新。"
        guard panel.runModal() == .OK, let url = panel.url else { return }; read(url)
    }
    func read(_ url: URL) {
        guard !busy, let model else { return }; reset(); busy = true
        task = Task { [weak self] in
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do { self?.preview = try await model.previewProfileUpdate(id: self?.profileID ?? UUID(), from: url) }
            catch is CancellationError { self?.status = "已取消预览。" }
            catch { self?.problem = "文件无法用于更新：请检查格式、证书材料及存储状态。" }
            self?.busy = false; self?.task = nil
        }
    }
    func apply() {
        guard canApply, let model, let preview else { return }; busy = true; problem = nil
        task = Task { [weak self] in
            do {
                try await model.applyProfileUpdate(preview)
                self?.preview = nil; self?.status = "配置已更新，旧版本已归档。请手动连接验证；无需保留导入文件。"
            } catch is CancellationError { self?.preview = nil; self?.status = "更新已取消，未提交的更改已恢复。" }
            catch { self?.preview = nil; self?.problem = error.localizedDescription }
            self?.confirmed = false; self?.identityConfirmed = false; self?.healthConfirmed = false
            self?.busy = false; self?.task = nil
        }
    }
}

struct ProfileHealthView: View {
    @ObservedObject var model: AppModel
    let profile: VPNProfile
    @StateObject private var controller: ProfileUpdateController
    @State private var updating: Bool
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel, profile: VPNProfile, updating: Bool = false) {
        self.model = model; self.profile = profile
        _controller = StateObject(wrappedValue: ProfileUpdateController(model: model, id: profile.id))
        _updating = State(initialValue: updating)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(updating ? "更新配置文件" : "配置健康检查", systemImage: updating ? "arrow.triangle.2.circlepath.doc.on.clipboard" : "checkmark.shield")
                .font(.system(size: 23, weight: .bold))
            Text(model.profiles.first(where: { $0.id == profile.id })?.name ?? profile.name).foregroundStyle(.secondary).lineLimit(1)
            Picker("操作", selection: $updating) { Text("健康检查").tag(false); Text("更新向导").tag(true) }
                .pickerStyle(.segmented).disabled(controller.busy).onChange(of: updating) { _ in controller.reset() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if updating { updateContent } else { healthContent }
                    if let problem = controller.problem { Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                    if let status = controller.status { Text(status).font(.callout).foregroundStyle(.secondary) }
                    if controller.busy { ProgressView().controlSize(.small) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard(cornerRadius: 16)
            }.frame(height: 400)
            Text("本地检查不连接服务器，不解锁私钥或检查服务端证书，也不代表证书链可信或 VPN 一定可用。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                if controller.busy { Button("取消当前操作") { controller.cancel() }.buttonStyle(ReferenceSecondaryButton()) }
                Spacer()
                Button("完成") { controller.reset(); dismiss() }.buttonStyle(ReferencePrimaryButton()).disabled(controller.busy)
            }
        }.padding(24).frame(width: 720).background(GlassAtmosphere()).interactiveDismissDisabled(controller.busy)
            .onAppear { model.profileHealth.requestRefresh(); Task { await model.profileHealth.refreshPermission() } }
    }
    private var healthContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("本地配置与证书").font(.headline); Spacer()
                Button(model.profileHealth.checking ? "检查中…" : "重新检查") { model.profileHealth.requestRefresh() }.disabled(model.profileHealth.checking || model.profileTransferInProgress)
            }
            if let report = model.profileHealth.reports[profile.id] { reportView(report) }
            else { Text(model.profileHealth.problem ?? "尚未完成检查。").foregroundStyle(.secondary) }
            Divider()
            Toggle("证书到期本地通知", isOn: Binding(get: { model.profileHealth.remindersEnabled }, set: { value in Task { await model.profileHealth.enableReminders(value) } }))
            Text("在 30 天、7 天、1 天内及过期后各提醒一次；应用需保持运行，关闭窗口仍可检查。通知不包含配置名或服务器地址。")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.profileHealth.notificationStatus).font(.caption).foregroundStyle(.secondary)
            Text("配置已由应用托管，连接使用独立副本，无需保留原位置的文件。").font(.callout)
            Button("选择新文件更新此配置…") { updating = true }.buttonStyle(ReferenceSecondaryButton())
        }
    }
    private var updateContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保留配置 ID、名称、分组、收藏、备注、路由策略及自定义规则。更新前归档旧版本；不会自动重连。")
                .font(.callout).foregroundStyle(.secondary)
            Button("选择新的 .ovpn 文件…") { controller.chooseFile() }.buttonStyle(ReferenceSecondaryButton()).disabled(controller.busy || !model.canUseProfileBackup)
            if let preview = controller.preview {
                Text(preview.filename).font(.headline).lineLimit(2)
                Text("原服务器：" + serverSummary(preview.previousServers)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("新服务器：" + serverSummary(preview.servers)).font(.caption).lineLimit(2)
                reportView(preview.health)
                if !preview.contentChanged { Text("文件内容与当前配置相同，无需更新。").foregroundStyle(.secondary) }
                if preview.identityChanged {
                    Label("服务器、认证方式或身份材料发生变化", systemImage: "person.badge.key.fill").font(.callout).foregroundStyle(.orange)
                    Toggle("确认身份变化；下次连接重新输入凭据", isOn: $controller.identityConfirmed)
                }
                if !preview.health.issues.isEmpty { Toggle("已查看健康检查结果，仍要保存此更新", isOn: $controller.healthConfirmed) }
                Toggle("确认更新并归档当前版本", isOn: $controller.confirmed)
                if !model.canUpdateProfile(profile.id) { Text("请先断开 VPN 并完成网络恢复后再更新。").font(.caption).foregroundStyle(.orange) }
                Button("确认更新") { controller.apply() }.buttonStyle(ReferencePrimaryButton()).disabled(!controller.canApply)
            }
        }.disabled(controller.busy)
    }
    private func reportView(_ report: ProfileHealthReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(report.title, systemImage: report.issues.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(report.issues.isEmpty ? Color.green : Color.orange).font(.headline)
            ForEach(report.issues) { issue in Text(issue.message).font(.callout).foregroundStyle(issue.severity == .error ? Color.red : Color.secondary) }
            ForEach(report.certificates) { item in
                HStack { Text(item.role.rawValue + "证书"); Spacer(); Text("到期：" + item.notAfter.formatted(date: .numeric, time: .omitted)) }.font(.caption)
            }
            Text("检查时间：" + report.checkedAt.formatted(date: .numeric, time: .shortened)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func serverSummary(_ values: [String]) -> String {
        guard !values.isEmpty else { return "无法从旧配置确认" }
        return values.prefix(3).joined(separator: "、") + (values.count > 3 ? " 等 \(values.count) 项" : "")
    }
}
