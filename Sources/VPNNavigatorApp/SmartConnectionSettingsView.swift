import SwiftUI
import AppKit
import VPNNavigatorCore

struct SmartConnectionSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var wifiDraft = ""
    private var smart: SmartConnectionController { model.smartConnection }
    private func binding<T>(_ key: WritableKeyPath<SmartConnectionPreferences, T>) -> Binding<T> {
        Binding(get: { smart.preferences[keyPath: key] }, set: { value in smart.update { $0[keyPath: key] = value } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "bolt.shield").foregroundStyle(GlassPalette.blue)
                Text("智能连接与状态通知").font(.system(size: 23, weight: .bold))
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用自动连接", isOn: binding(\.enabled))
                        Text(smart.status).font(.system(size: 12)).foregroundStyle(.secondary)
                        if smart.preferences.enabled {
                            Button(smart.preferences.paused ? "恢复自动连接" : "暂停自动连接") { smart.togglePause() }
                                .buttonStyle(ReferenceSecondaryButton())
                        }
                        Picker("连接配置", selection: binding(\.profileID)) {
                            Text("最近成功连接的配置").tag(Optional<UUID>.none)
                            ForEach(model.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                            if let id = smart.preferences.profileID, !model.profiles.contains(where: { $0.id == id }) {
                                Text("原配置已删除，请重新选择").tag(Optional(id))
                            }
                        }
                        Text("最近成功配置依据助手确认的连接记录选择。尚无记录时，请先手动连接一次或指定固定配置。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider().opacity(0.25)
                        Text("何时连接").font(.headline)
                        Toggle("应用启动后", isOn: binding(\.onLaunch))
                        Toggle("系统唤醒后", isOn: binding(\.onWake))
                        Toggle("网络恢复或切换后", isOn: binding(\.onNetworkRestore))
                        Text("登录后自动连接还需在连接偏好中开启“登录时启动”。自动连接只在应用运行时生效。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider().opacity(0.25)
                        Picker("允许的网络", selection: binding(\.networkScope)) {
                            ForEach(SmartNetworkScope.allCases) { Text($0.title).tag($0) }
                        }
                        if smart.preferences.networkScope == .specifiedWiFi {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(smart.preferences.wifiNames, id: \.self) { name in
                                    HStack { Text(name).lineLimit(1); Spacer(); Button("移除") { smart.update { $0.wifiNames.removeAll { $0 == name } } } }
                                }
                                HStack {
                                    TextField("输入精确 Wi-Fi 名称", text: $wifiDraft)
                                    Button("添加") {
                                        let name = wifiDraft
                                        smart.update { $0.wifiNames.append(name) }
                                        if smart.preferences.wifiNames.contains(name) { wifiDraft = "" }
                                    }.disabled(wifiDraft.isEmpty)
                                }
                                HStack {
                                    Button("授权读取 Wi-Fi 名称…") { smart.requestWiFiAccess() }
                                    Button("位置服务设置…") {
                                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"), !NSWorkspace.shared.open(url) {
                                            model.message = "请打开系统设置 → 隐私与安全性 → 定位服务，检查 VPN Navigator 的授权。"
                                        }
                                    }
                                    if let name = smart.network.wifiName {
                                        Button("添加当前 Wi-Fi") { smart.update { if !$0.wifiNames.contains(name) { $0.wifiNames.append(name) } } }
                                            .disabled(smart.preferences.wifiNames.contains(name))
                                    }
                                }.buttonStyle(ReferenceSecondaryButton())
                                Text(smart.network.wifiName == nil ? "当前名称不可读取。未能核验名称时不会自动连接。" : "当前 Wi-Fi 名称已可读取。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Text("名称区分大小写，不会按名称推断网络是否可信。位置授权仅用于读取 Wi-Fi 名称，不获取地理坐标。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("允许在按流量计费的网络自动连接", isOn: binding(\.allowExpensive))
                        Text("触发后等待网络稳定并重新核验助手。已有 VPN 会话时不会切换；手动断开会暂停自动连接，需主动恢复。需要认证、配置异常或有待恢复记录时，请手动处理。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("活动会话的断线重连仍使用连接偏好中的原有策略；受管模式安全重连需先开启断线保护。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(18).glassCard(cornerRadius: 16)
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("启用系统状态通知", isOn: Binding(get: { smart.preferences.notifications }, set: { enabled in Task { await smart.enableNotifications(enabled) } }))
                        Text(smart.notificationStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                        Picker("通知范围", selection: binding(\.noticeScope)) {
                            ForEach(StatusNoticeScope.allCases) { Text($0.title).tag($0) }
                        }.disabled(!smart.preferences.notifications)
                        Toggle("播放通知声音", isOn: binding(\.sound)).disabled(!smart.preferences.notifications)
                        HStack {
                            Button("发送测试通知") { Task { await smart.deliver(.test) } }.disabled(!smart.preferences.notifications)
                            Button("系统通知设置…") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"), !NSWorkspace.shared.open(url) {
                                    model.message = "请打开系统设置 → 通知 → VPN Navigator，检查通知授权。"
                                }
                            }
                            Button("刷新授权状态") { Task { await smart.refreshNotificationPermission() } }
                        }.buttonStyle(ReferenceSecondaryButton())
                        Text("异常、认证请求和恢复未完成会分别提示。同一会话事件只提醒一次；通知不包含配置名称、服务器、Wi-Fi 名称或凭据。点击通知打开主窗口。横幅与声音受系统设置及专注模式控制。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(18).glassCard(cornerRadius: 16)
                }.padding(2)
            }.frame(height: 470)
            HStack {
                Text("修改立即保存；恢复自动连接后等待下一次触发。").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(); Button("完成") { dismiss() }.buttonStyle(ReferencePrimaryButton())
            }
        }.padding(24).frame(width: 700).background(GlassAtmosphere())
            .task { await smart.refreshNotificationPermission() }
    }
}
