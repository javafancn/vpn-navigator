import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import VPNNavigatorCore

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
            SecureField(challenge.kind == .privateKey ? "私钥密码" : "一次性验证码", text: $response)
                .textFieldStyle(.plain).referenceInput()
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
                }.buttonStyle(ReferencePrimaryButton()).disabled(response.isEmpty || submitting)
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
            Label("国内直连需要先下载或导入 IPv4 规则；IPv6 地区分流仍未提供，实验性断线保护需完成发布验收。", systemImage: "info.circle")
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
                Text("全局 VPN 和国内直连遇到重连事件时停止会话，防止在未验证的网络路径上继续运行。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider().opacity(0.25)
                Toggle("断线保护（实验性，全局 VPN / 国内直连）", isOn: $model.killSwitch)
                Text("启用时会检查 PF 环境、重置现有网络连接并阻断物理 IPv6。意外断线后保护会保留，需手动断开或恢复网络。完整真机防泄漏验收尚待完成。")
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
            }.padding(20).glassCard(cornerRadius: 16)
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
