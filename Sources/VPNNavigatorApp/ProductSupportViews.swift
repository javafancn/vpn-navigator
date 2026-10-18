import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import VPNNavigatorCore

struct AccountCredentialsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("身份验证").font(.system(size: 24, weight: .bold))
            Text(model.selected?.name ?? "当前配置").font(.system(size: 14)).foregroundStyle(.secondary)
            TextField("用户名", text: $model.username).textFieldStyle(.plain).referenceInput()
            SecureField("密码", text: $model.password).textFieldStyle(.plain).referenceInput()
            Toggle("在此 Mac 的 Keychain 中保存用户名与密码", isOn: $model.rememberCredentials)
            HStack {
                Button("取消") { model.password = ""; dismiss() }.buttonStyle(ReferenceSecondaryButton())
                Spacer()
                Button("连接") { dismiss(); Task { await model.connectSelected() } }
                    .buttonStyle(ReferencePrimaryButton()).disabled(model.username.isEmpty || model.password.isEmpty)
            }
        }.padding(24).frame(width: 460).background(GlassAtmosphere())
    }
}

struct MaintenanceAssistantView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var removeProfiles = false
    @State private var prepared = false
    @State private var preparing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("升级与卸载准备").font(.system(size: 24, weight: .bold))
            Text("先停止 VPN、恢复网络并停用本应用后台服务及登录启动，再交由系统安装器升级或 Finder 移除应用。")
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            Toggle("同时删除全部连接配置、历史版本与已保存凭据", isOn: $removeProfiles)
                .disabled(preparing || prepared)
            Text("默认保留本地配置。勾选删除后无法撤销；不会删除其他应用或系统的凭据。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary) }
            HStack {
                Button(preparing ? "准备中…" : "断开并停用后台服务") {
                    preparing = true
                    Task { prepared = await model.prepareMaintenance(removeProfiles: removeProfiles); preparing = false }
                }.buttonStyle(ReferencePrimaryButton()).disabled(preparing || prepared)
                Spacer()
            }
            HStack {
                Button("在 Finder 中显示应用") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(!prepared)
                Button("下载已验证的更新…") {
                    dismiss(); Task { await model.downloadVerifiedUpdate() }
                }.buttonStyle(ReferenceSecondaryButton()).disabled(!prepared || model.availableInstaller == nil)
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(ReferenceSecondaryButton()).disabled(preparing)
            }
        }.padding(24).frame(width: 680).background(GlassAtmosphere()).interactiveDismissDisabled(preparing)
    }
}

struct AuthenticationChallengeView: View {
    @EnvironmentObject private var model: AppModel
    let challenge: AuthenticationChallenge
    @State private var response = ""
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(challenge.kind == .privateKey ? "解锁私钥" : "额外身份验证")
                .font(.system(size: 24, weight: .bold))
            Text(challenge.prompt).font(.system(size: 14)).textSelection(.enabled)
            if challenge.responseRequired {
                SecureField(challenge.kind == .privateKey ? "私钥密码" : "一次性验证码", text: $response)
                    .textFieldStyle(.plain).referenceInput()
            } else {
                Text("请先完成服务端要求的验证，再点击继续。无需输入验证码。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text("本次输入仅用于当前认证，不保存至 Keychain 或诊断报告。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("取消连接") { response = ""; Task { await model.disconnect() } }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(submitting)
                Spacer()
                Button(submitting ? "正在提交…" : "继续") {
                    submitting = true
                    let secret = response; response = ""
                    Task { await model.respondToChallenge(challenge, value: secret); submitting = false }
                }.buttonStyle(ReferencePrimaryButton()).disabled((challenge.responseRequired && response.isEmpty) || submitting)
            }
        }.padding(24).frame(width: 460).background(GlassAtmosphere())
            .interactiveDismissDisabled()
            .onDisappear { response = "" }
    }
}

struct SetupAssistantView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    private var signed: Bool { PrivilegedServiceTrust.helperRequirement() != nil }
    private var engine: Bool {
        Bundle.main.resourceURL.map {
            FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("openvpn").path)
        } ?? false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                BrandMark(size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("连接前检查").font(.system(size: 24, weight: .bold))
                    Text("准备应用、权限与配置，完成后即可开始使用。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 0) {
                checkRow("应用签名", detail: signed ? "已检测到开发者团队身份" : "当前为开发预览包，请安装正式签名版本", ready: signed)
                Divider().opacity(0.25)
                checkRow("OpenVPN 引擎", detail: engine ? "已找到内置引擎；连接时会核验签名" : "当前安装包未包含引擎，暂不能连接 VPN", ready: engine)
                Divider().opacity(0.25)
                checkRow("安装位置", detail: "/Applications/VPN Navigator.app", ready: Bundle.main.bundleURL.path == "/Applications/VPN Navigator.app")
                Divider().opacity(0.25)
                HStack {
                    checkRow("后台助手", detail: model.helperStatus, ready: model.helperStatus == "已启用")
                    Button("启用…") { model.requestHelper() }
                        .buttonStyle(ReferenceSecondaryButton()).disabled(!signed || !engine)
                    Button("系统授权…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(ReferenceSecondaryButton())
                }.padding(.trailing, 14)
                Divider().opacity(0.25)
                HStack {
                    checkRow("连接配置", detail: "已导入 \(model.profiles.count) 个配置", ready: !model.profiles.isEmpty)
                    Button("导入 .ovpn…") { importing = true }
                        .buttonStyle(ReferenceSecondaryButton()).padding(.trailing, 14)
                }
            }.glassCard(cornerRadius: 16)
            Label("国内直连使用已校验的本地规则，支持在线更新与离线导入。IPv6 地区分流未提供，实验性断线保护需完成发布验收。", systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("重新检查") { Task { await model.refreshConnectionStatus() } }
                    .buttonStyle(ReferenceSecondaryButton())
                Spacer()
                Button("完成") {
                    UserDefaults.standard.set(true, forKey: "setupAssistantDismissed")
                    dismiss()
                }.buttonStyle(ReferencePrimaryButton())
            }
        }
        .padding(24).frame(width: 660)
        .background(GlassAtmosphere())
        .fileImporter(isPresented: $importing, allowedContentTypes: [.init(filenameExtension: "ovpn")!]) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .task { await model.refreshConnectionStatus() }
    }
    private func checkRow(_ title: String, detail: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.orange).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClientPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("连接偏好").font(.system(size: 24, weight: .bold))
            VStack(alignment: .leading, spacing: 18) {
                Picker("连接与认证超时", selection: Binding(
                    get: { model.sessionPreferences.connectionTimeout },
                    set: { model.connectionTimeout = $0 })) {
                    ForEach([30, 60, 90, 120, 180], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Toggle("Original 模式断线后自动重连", isOn: $model.reconnectOriginal)
                Text("Original 使用 OpenVPN 内部重连；受管模式仅在已启用并核验断线保护时，才允许额外重试。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider().opacity(0.25)
                Toggle("断线保护（实验性，全局 VPN / 国内直连）", isOn: $model.killSwitch)
                Text("保护启用、重建、收紧规则或解除时会重置现有网络连接（含其它 VPN），并阻断物理 IPv6。异常时保护保留，手动断开或恢复网络可解除。完整真机验收尚待完成。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("受管模式安全重连（最多 3 次 / 10 分钟）", isOn: $model.reconnectManaged)
                    .disabled(!model.killSwitch)
                Text("重连期间持续保留防火墙，旧进程、DNS 和路由未安全恢复时不会启动新会话。服务器地址固定为本次已解析的 IPv4。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider().opacity(0.25)
                Toggle("登录时启动 VPN Navigator", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                            model.message = "登录启动设置失败：\(error.localizedDescription)"
                        }
                    }
            }.padding(20).glassCard(cornerRadius: 16).disabled(model.maintenanceInProgress)
            Text("连接偏好在下一次连接时生效。登录启动不会自动建立 VPN 连接。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button("完成") { dismiss() }.buttonStyle(ReferencePrimaryButton()) }
        }.padding(24).frame(width: 520).background(GlassAtmosphere())
    }
}

struct DiagnosticHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("会话诊断").font(.system(size: 24, weight: .bold))
            Text("仅记录故障类别与时间，不保存原始引擎日志、地址、域名、证书或凭据。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.eventHistory.isEmpty {
                        Text("暂无会话事件。后台助手未启用时，仅显示本机操作记录。")
                            .foregroundStyle(.secondary).padding(20)
                    }
                    ForEach(model.eventHistory.reversed()) { event in
                        HStack(alignment: .top, spacing: 12) {
                            Text(event.date, style: .time).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary).frame(width: 82, alignment: .leading)
                            Text(event.code.summary).font(.system(size: 14))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 16).padding(.vertical, 6)
                    }
                }.padding(.vertical, 10)
            }.frame(height: 320).glassCard(cornerRadius: 16)
            HStack {
                Button("刷新") { Task { await model.refreshDiagnostics() } }.buttonStyle(ReferenceSecondaryButton())
                Button("导出脱敏报告…") { Task { await model.exportDiagnostics() } }.buttonStyle(ReferenceSecondaryButton())
                Spacer()
                Button("完成") { dismiss() }.buttonStyle(ReferencePrimaryButton())
            }
        }.padding(24).frame(width: 660).background(GlassAtmosphere())
            .task { await model.refreshDiagnostics() }
    }
}
