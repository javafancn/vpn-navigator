import SwiftUI
import VPNNavigatorCore

struct LanguageSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preference = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "") ?? .system
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("界面语言")).font(.system(size: 24, weight: .bold))
            Picker(L10n.text("语言"), selection: $preference) {
                ForEach(AppLanguage.allCases) { language in Text(language.title).tag(language) }
            }.pickerStyle(.radioGroup)
            Text(L10n.text("语言偏好立即保存，下次启动应用后生效。当前 VPN 会话不会中断，也不会自动退出或重连。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L10n.text("切换覆盖应用界面、菜单、通知和配置错误提示。配置名称、分组、服务器地址及原始技术输出保持原值。"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(L10n.text("完成")) { dismiss() }.buttonStyle(ReferencePrimaryButton()).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 480).background(GlassAtmosphere())
        .onChange(of: preference) { AppLanguage.save($0, defaults: .standard) }
    }
}
