import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import VPNNavigatorCore

struct AccountCredentialsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("身份验证")).font(.system(size: 24, weight: .bold))
            Text(model.selected?.name ?? L10n.text("当前配置")).font(.system(size: 14)).foregroundStyle(.secondary)
            TextField(L10n.text("用户名"), text: $model.username).textFieldStyle(.plain).referenceInput()
            SecureField(L10n.text("密码"), text: $model.password).textFieldStyle(.plain).referenceInput()
            Toggle(L10n.text("在此 Mac 的 Keychain 中保存用户名与密码"), isOn: $model.rememberCredentials)
            HStack {
                Button(L10n.text("取消")) { model.password = ""; dismiss() }.buttonStyle(ReferenceSecondaryButton())
                Spacer()
                Button(L10n.text("连接")) { dismiss(); Task { await model.connectSelected() } }
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
            Text(L10n.text("升级与卸载准备")).font(.system(size: 24, weight: .bold))
            Text(BuildChannel.isLocal ? L10n.text("先恢复网络并停用后台服务，再通过系统安装器升级或完整卸载。直接将应用拖入废纸篓会保留系统组件。") : L10n.text("先停止 VPN、恢复网络并停用本应用后台服务及登录启动，再交由系统安装器升级或 Finder 移除应用。"))
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
            if let issue = model.installationIssue {
                Text(issue).font(.system(size: 13)).foregroundStyle(.secondary)
                Button(L10n.text("选择安装包修复…")) { model.openLocalInstaller() }
                    .buttonStyle(ReferencePrimaryButton()).disabled(!model.canRepairInterruptedInstallation)
            }
            Toggle(L10n.text("同时删除全部连接配置、历史版本与已保存凭据"), isOn: $removeProfiles)
                .disabled(preparing || prepared || model.installationIssue != nil)
            Text(L10n.text("默认保留本地配置。勾选删除后无法撤销；不会删除其他应用或系统的凭据。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let message = model.message { Text(message).font(.system(size: 13)).foregroundStyle(.secondary) }
            HStack {
                Button(preparing ? L10n.text("准备中…") : L10n.text("断开并停用后台服务")) {
                    preparing = true
                    Task { prepared = await model.prepareMaintenance(removeProfiles: removeProfiles); preparing = false }
                }.buttonStyle(ReferencePrimaryButton()).disabled(preparing || prepared || model.installationIssue != nil)
                Spacer()
            }
            HStack {
                if BuildChannel.isLocal {
                    Button(L10n.text("选择本地更新包…")) { model.openLocalInstaller() }
                        .buttonStyle(ReferenceSecondaryButton()).disabled(!prepared)
                    Button(L10n.text("卸载本地程序…")) { model.openLocalUninstaller() }
                        .buttonStyle(ReferenceSecondaryButton()).disabled(!prepared)
                } else {
                Button(L10n.text("在 Finder 中显示应用")) { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(!prepared)
                Button(L10n.text("下载已验证的更新…")) {
                    dismiss(); Task { await model.downloadVerifiedUpdate() }
                }.buttonStyle(ReferenceSecondaryButton()).disabled(!prepared || model.availableInstaller == nil)
                }
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.buttonStyle(ReferenceSecondaryButton()).disabled(preparing)
            }
        }.padding(24).frame(width: 680)
            .background(GlassAtmosphere(onWindow: { $0.preventsApplicationTerminationWhenModal = false }))
            .interactiveDismissDisabled(preparing)
    }
}

struct AuthenticationChallengeView: View {
    @EnvironmentObject private var model: AppModel
    let challenge: AuthenticationChallenge
    @State private var response = ""
    @State private var submitting = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(challenge.kind == .privateKey ? L10n.text("解锁私钥") : L10n.text("额外身份验证"))
                .font(.system(size: 24, weight: .bold))
            Text(challenge.kind == .privateKey ? L10n.text("输入此配置私钥的解锁密码") : challenge.prompt).font(.system(size: 14)).textSelection(.enabled)
            if challenge.responseRequired {
                SecureField(challenge.kind == .privateKey ? L10n.text("私钥密码") : L10n.text("一次性验证码"), text: $response)
                    .textFieldStyle(.plain).referenceInput()
            } else {
                Text(L10n.text("请先完成服务端要求的验证，再点击继续。无需输入验证码。"))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(L10n.text("本次输入仅用于当前认证，不保存至 Keychain 或诊断报告。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("取消连接")) { response = ""; Task { await model.disconnect() } }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(submitting)
                Spacer()
                Button(submitting ? L10n.text("正在提交…") : L10n.text("继续")) {
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
    @State private var signatureReady: Bool?
    private var signed: Bool { signatureReady == true }
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
                    Text(L10n.text("连接前检查")).font(.system(size: 24, weight: .bold))
                    Text(BuildChannel.label + L10n.text(" · 准备应用、权限与配置"))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(spacing: 0) {
                checkRow(BuildChannel.isLocal ? L10n.text("本地安装批准") : L10n.text("应用签名"), detail: signatureReady == nil ? L10n.text("正在核验程序身份…") : BuildChannel.isLocal ? (signed ? L10n.text("管理员已批准此版本；本地运行时签名，未公证") : L10n.text("请用可信 Local.pkg 安装或修复")) : (signed ? L10n.text("已检测到开发者团队身份") : L10n.text("当前为开发预览包，请安装正式签名版本")), ready: signed)
                Divider().opacity(0.25)
                checkRow(L10n.text("OpenVPN 引擎"), detail: engine ? L10n.text("已找到内置引擎；连接时会核验签名") : L10n.text("当前安装包未包含引擎，暂不能连接 VPN"), ready: engine)
                Divider().opacity(0.25)
                checkRow(L10n.text("安装位置"), detail: "/Applications/VPN Navigator.app", ready: Bundle.main.bundleURL.path == "/Applications/VPN Navigator.app")
                Divider().opacity(0.25)
                HStack {
                    checkRow(L10n.text("后台助手"), detail: model.helperStatus, ready: model.helperStatus == L10n.text("已启用"))
                    Button(BuildChannel.isLocal ? (model.installationIssue == nil ? L10n.text("安装 / 启用…") : L10n.text("修复安装…")) : L10n.text("启用…")) { model.requestHelper() }
                        .buttonStyle(ReferenceSecondaryButton()).disabled(!BuildChannel.isLocal && (!signed || !engine))
                    Button(L10n.text("系统授权…")) { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(ReferenceSecondaryButton())
                }.padding(.trailing, 14)
                Divider().opacity(0.25)
                HStack {
                    checkRow(L10n.text("连接配置"), detail: L10n.format("已导入 {0} 个配置", [String(describing: model.profiles.count)]), ready: !model.profiles.isEmpty)
                    Button(L10n.text("导入 .ovpn…")) { importing = true }
                        .buttonStyle(ReferenceSecondaryButton()).padding(.trailing, 14)
                }
            }.glassCard(cornerRadius: 16)
            Label(L10n.text("国内直连使用已校验的本地规则，支持在线更新与离线导入。IPv6 地区分流未提供，实验性断线保护需完成发布验收。"), systemImage: "info.circle")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.text("重新检查")) { Task { await model.refreshConnectionStatus(); await refreshSignature() } }
                    .buttonStyle(ReferenceSecondaryButton())
                Spacer()
                Button(L10n.text("完成")) {
                    UserDefaults.standard.set(true, forKey: "setupAssistantDismissed")
                    dismiss()
                }.buttonStyle(ReferencePrimaryButton())
            }
            if let issue = model.installationIssue { Text(issue).font(.system(size: 13)).foregroundStyle(.secondary) }
        }
        .padding(24).frame(width: 660)
        .background(GlassAtmosphere(onWindow: { $0.preventsApplicationTerminationWhenModal = false }))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.init(filenameExtension: "ovpn")!]) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .task { await model.refreshConnectionStatus() }
        .task(id: model.helperStatus + (model.installationIssue ?? "")) { await refreshSignature() }
    }
    @MainActor private func refreshSignature() async {
        signatureReady = nil
        let verified = await Task.detached(priority: .utility) {
            PrivilegedServiceTrust.helperRequirement() != nil
        }.value
        guard !Task.isCancelled else { return }
        signatureReady = verified
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
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("连接偏好")).font(.system(size: 24, weight: .bold))
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(L10n.text("智能连接与状态通知…")) { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.showingSmartConnection = true } }
                    .buttonStyle(ReferenceSecondaryButton())
                Picker(L10n.text("连接与认证超时"), selection: Binding(
                    get: { model.sessionPreferences.connectionTimeout },
                    set: { model.connectionTimeout = $0 })) {
                    ForEach([30, 60, 90, 120, 180], id: \.self) { Text(L10n.format("{0} 秒", [String(describing: $0)])).tag($0) }
                }
                Toggle(L10n.text("Original 模式断线后自动重连"), isOn: $model.reconnectOriginal)
                Text(L10n.text("Original 使用 OpenVPN 内部重连；受管模式仅在已启用并核验断线保护时，才允许额外重试。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider().opacity(0.25)
                Toggle(L10n.text("断线保护（实验性，全局 VPN / 国内直连）"), isOn: $model.killSwitch)
                Text(L10n.text("保护启用、重建、收紧规则或解除时会重置现有网络连接（含其它 VPN），按策略限制 IPv4／IPv6 物理出口。异常时保护保留，手动断开或恢复网络可解除。完整真机验收尚待完成。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle(L10n.text("受管模式必须建立 IPv4＋IPv6 双栈"), isOn: $model.requireDualStack)
                Text(L10n.text("默认按服务器分配的地址自动配置。要求双栈时缺少任一地址族会拒绝连接；未承载的地址族仍须满足保护条件。修改在下次连接生效。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle(L10n.text("受管模式安全重连（最多 3 次 / 10 分钟）"), isOn: $model.reconnectManaged)
                    .disabled(!model.killSwitch)
                Text(L10n.text("重连期间持续保留防火墙，旧进程、DNS 和路由未安全恢复时不会启动新会话。服务器地址固定为本次已解析的 IPv4 或 IPv6。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Divider().opacity(0.25)
                Toggle(L10n.text("每天自动更新国内 IPv4／IPv6 规则"), isOn: Binding(
                    get: { model.automaticRulesEnabled },
                    set: { enabled in Task { await model.setAutomaticRules(enabled) } }))
                Text(L10n.format("规则服务：{0}", [String(describing: model.rulesServiceStatus)])).font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle(L10n.text("登录时启动 VPN Navigator"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { enabled in Task { await model.setLaunchAtLogin(enabled) } }))
                Text(L10n.format("登录服务：{0}", [String(describing: model.loginServiceStatus)])).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(L10n.text("升级或修复会暂时停用服务；安装完成后，重新打开应用会恢复上述选择。关闭自动更新后，仍可手动更新或导入规则。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                if let issue = model.backgroundServicesIssue {
                    Text(issue).font(.system(size: 12)).foregroundStyle(.orange)
                }
                HStack {
                    Button(model.backgroundServicesBusy ? L10n.text("应用中…") : L10n.text("按偏好重试")) { Task { await model.restoreBackgroundServices() } }
                        .buttonStyle(ReferenceSecondaryButton())
                    Button(L10n.text("系统授权…")) { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(ReferenceSecondaryButton())
                }
                Divider().opacity(0.25)
                Picker(L10n.text("全局快速打开"), selection: $model.quickAccessShortcut) {
                    ForEach(QuickAccessShortcut.allCases) { Text($0.title).tag($0) }
                }
                Text(model.quickAccessShortcutStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(L10n.text("应用运行时可从其他应用唤起面板；关闭窗口后仍可使用。应用内也可按 ⇧⌘P，或从菜单栏打开。"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button(L10n.text("重试快捷键注册")) { model.quickAccess.retryShortcut() }
                    .buttonStyle(ReferenceSecondaryButton()).disabled(model.quickAccessShortcut == .disabled)
            }.padding(20).glassCard(cornerRadius: 16)
                .disabled(model.maintenanceInProgress || model.backgroundServicesBusy)
            }.frame(maxHeight: 460)
            Text(L10n.text("连接偏好在下一次连接时生效。自动连接需在“智能连接与状态通知”中单独开启。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.text("完成")) { dismiss() }.buttonStyle(ReferencePrimaryButton()) }
        }.padding(24).frame(width: 560).background(GlassAtmosphere())
            .task { model.refreshBackgroundServiceStatus() }
    }
}

struct DiagnosticHistoryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("会话诊断")).font(.system(size: 24, weight: .bold))
            Text(L10n.text("仅记录故障类别与时间，不保存原始引擎日志、地址、域名、证书或凭据。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.eventHistory.isEmpty {
                        Text(L10n.text("暂无会话事件。后台助手未启用时，仅显示本机操作记录。"))
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
                Button(L10n.text("刷新")) { Task { await model.refreshDiagnostics() } }.buttonStyle(ReferenceSecondaryButton())
                Button(L10n.text("导出脱敏报告…")) { Task { await model.exportDiagnostics() } }.buttonStyle(ReferenceSecondaryButton())
                Spacer()
                Button(L10n.text("完成")) { dismiss() }.buttonStyle(ReferencePrimaryButton())
            }
        }.padding(24).frame(width: 660).background(GlassAtmosphere())
            .task { await model.refreshDiagnostics() }
    }
}
