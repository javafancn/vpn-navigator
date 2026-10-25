import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VPNNavigatorCore

struct DecryptedProfileBackup: Sendable {
    let snapshot: ProfileBackupSnapshot
    let existing: [VPNProfile]
}

@MainActor
final class ProfileBackupController: ObservableObject {
    enum Mode: String, CaseIterable { case export = "创建备份", restore = "从备份恢复" }
    @Published var mode: Mode = .export
    @Published var password = ""
    @Published var confirmation = ""
    @Published var acknowledged = false
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    @Published private(set) var problem: String?
    @Published private(set) var selectedFile: URL?
    @Published private(set) var preview: DecryptedProfileBackup?
    private weak var model: AppModel?
    private var task: Task<Void, Never>?
    init(model: AppModel) { self.model = model }
    var canExport: Bool { !busy && acknowledged && password.count >= 12 && password.utf8.count <= 1024 && password == confirmation && model?.profiles.isEmpty == false }
    var canDecrypt: Bool { !busy && selectedFile != nil && !password.isEmpty && password.utf8.count <= 1024 }
    var canRestore: Bool { !busy && acknowledged && preview?.snapshot.entries.isEmpty == false && model?.canRestoreProfileBackup == true }
    func reset() { guard !busy else { return }; password = ""; confirmation = ""; acknowledged = false; preview = nil; status = nil; problem = nil; selectedFile = nil }
    func cancel() { task?.cancel(); status = "正在取消，等待当前安全步骤结束…" }
    func clearSecrets() { task?.cancel(); password = ""; confirmation = ""; preview = nil }
    func chooseFile() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [Self.contentType]; panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false; panel.message = "选择 VPN Navigator 加密备份。解密和预览均在本机进行。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFile = url; preview = nil; acknowledged = false; password = ""; problem = nil; status = nil
    }
    static var contentType: UTType { UTType(exportedAs: "com.javafancn.vpn-navigator.backup", conformingTo: .data) }
    func export() {
        guard canExport, let model else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [Self.contentType]
        panel.nameFieldStringValue = "VPNNavigator-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).vpnnavbackup"
        panel.message = "备份可能包含私钥与证书；密码无法找回，请使用独立长密码并妥善保存。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let secret = password; password = ""; confirmation = ""; busy = true; problem = nil; status = "正在读取配置并加密…"
        task = Task { [weak self] in
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do { let count = try await model.createEncryptedBackup(password: secret, to: url); self?.status = "已加密保存 \(count) 个配置及其历史版本。" }
            catch is CancellationError { self?.status = "已取消，本次未提交备份。" }
            catch { self?.problem = error.localizedDescription; self?.status = nil }
            self?.busy = false; self?.task = nil
        }
    }
    func decrypt() {
        guard canDecrypt, let model, let url = selectedFile else { return }
        let secret = password; password = ""; busy = true; problem = nil; status = "正在本机解密并检查备份…"
        task = Task { [weak self] in
            let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
            do { let value = try await model.previewEncryptedBackup(at: url, password: secret); self?.preview = value; self?.status = nil; self?.acknowledged = false }
            catch is CancellationError { self?.status = "已取消解密。" }
            catch { self?.problem = error.localizedDescription; self?.status = nil }
            self?.busy = false; self?.task = nil
        }
    }
    func restore() {
        guard canRestore, let model, let value = preview else { return }
        busy = true; problem = nil; status = "正在恢复，现有配置将保留…"
        task = Task { [weak self] in
            do { let count = try await model.restoreEncryptedBackup(value); self?.status = "已新增恢复 \(count) 个配置。请手动选择配置连接，并按需重新输入凭据。"; self?.preview = nil; self?.acknowledged = false }
            catch is CancellationError { self?.status = "已取消恢复。" }
            catch {
                if let failure = error as? ProfileBackupFailure, case .staleLibrary = failure { self?.preview = nil; self?.acknowledged = false }
                self?.problem = error.localizedDescription; self?.status = nil
            }
            self?.busy = false; self?.task = nil
        }
    }
}

struct ProfileBackupView: View {
    @ObservedObject private var model: AppModel
    @StateObject private var controller: ProfileBackupController
    @Environment(\.dismiss) private var dismiss
    init(model: AppModel) { self.model = model; _controller = StateObject(wrappedValue: ProfileBackupController(model: model)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("加密备份与迁移", systemImage: "lock.doc").font(.system(size: 23, weight: .bold))
            Picker("操作", selection: $controller.mode) {
                ForEach(ProfileBackupController.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).disabled(controller.busy)
                .onChange(of: controller.mode) { _ in controller.reset() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("完整备份配置、原始文件、自包含证书材料、分组、收藏、分流规则与历史版本。恢复将新增配置，不覆盖现有内容。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if controller.mode == .export { exportFields }
                    else { restoreFields }
                    if let problem = controller.problem { Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 13)).foregroundStyle(.orange) }
                    if let status = controller.status { Text(status).font(.system(size: 13)).foregroundStyle(.secondary) }
                    if controller.busy { ProgressView().controlSize(.small) }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassCard(cornerRadius: 16)
            }.frame(height: 405)
            Text("不包含钥匙串、输入框密码、系统授权、自动连接偏好或网络恢复记录。文件最多 16 MB；加密与解密均在本机完成。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                if controller.busy { Button("取消当前操作") { controller.cancel() }.buttonStyle(ReferenceSecondaryButton()) }
                Spacer()
                Button("完成") { controller.clearSecrets(); dismiss() }.buttonStyle(ReferencePrimaryButton()).disabled(controller.busy)
            }
        }.padding(24).frame(width: 690).background(GlassAtmosphere()).onDisappear { controller.clearSecrets() }
    }
    private var exportFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前配置库：\(model.profiles.count) 个配置").font(.headline)
            SecureField("备份密码（至少 12 个字符）", text: $controller.password)
            SecureField("再次输入备份密码", text: $controller.confirmation)
            if !controller.confirmation.isEmpty && controller.password != controller.confirmation { Text("两次输入的密码不一致。").font(.caption).foregroundStyle(.orange) }
            Toggle("我已了解：备份可能包含私钥；密码无法找回", isOn: $controller.acknowledged)
            Button("加密并保存…") { controller.export() }.buttonStyle(ReferencePrimaryButton()).disabled(!controller.canExport || !model.canUseProfileBackup)
        }.disabled(controller.busy)
    }
    private var restoreFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("选择加密备份…") { controller.chooseFile() }.buttonStyle(ReferenceSecondaryButton()).disabled(controller.busy)
            if let file = controller.selectedFile { Text(file.lastPathComponent).font(.system(size: 12)).lineLimit(2) }
            if let preview = controller.preview {
                Text("将新增 \(preview.snapshot.entries.count) 个配置、\(preview.snapshot.revisionCount) 个历史版本").font(.headline)
                Text("现有 \(preview.existing.count) 个配置保留；同名配置也会作为新条目添加。不会自动连接或开启系统服务。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(preview.snapshot.entries, id: \.profile.id) { entry in
                        HStack { Text(entry.profile.name).lineLimit(1); Spacer(); Text(entry.profile.mode.title).font(.caption).foregroundStyle(.secondary); Text("\(entry.revisions.count) 个版本").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Toggle("确认新增上述配置及历史版本", isOn: $controller.acknowledged).disabled(controller.busy)
                if !model.canRestoreProfileBackup { Text("请先断开 VPN 并完成网络恢复，再确认恢复配置。").font(.caption).foregroundStyle(.orange) }
                Button("确认恢复") { controller.restore() }.buttonStyle(ReferencePrimaryButton()).disabled(!controller.canRestore)
            } else {
                SecureField("输入备份密码", text: $controller.password).disabled(controller.busy)
                Button("解密并预览") { controller.decrypt() }.buttonStyle(ReferencePrimaryButton()).disabled(!controller.canDecrypt || !model.canUseProfileBackup)
            }
        }
    }
}
