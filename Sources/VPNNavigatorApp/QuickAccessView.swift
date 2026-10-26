import SwiftUI
import VPNNavigatorCore

struct QuickAccessView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var state: QuickAccessState
    @FocusState private var searchFocused: Bool
    let onSelect: (UUID) -> Void
    let onActivate: () -> Void
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let onNormalize: () -> Void
    let onOpenMain: () -> Void
    private var results: [VPNProfile] { QuickProfileSearch.results(model.profiles, query: state.query) }
    private var action: QuickAccessAction { state.selectedID.map { model.quickAccessAction(for: $0) } ?? .blocked }
    private var actionTitle: String {
        switch action {
        case .blocked: return "请在主窗口检查状态"
        case .openMain: return "查看连接"
        case .connect: return "连接"
        case .requestSwitch: return "切换连接…"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
                TextField("搜索配置名称、分组或文件名", text: $state.query)
                    .textFieldStyle(.plain).font(.system(size: 20)).focused($searchFocused)
                    .accessibilityIdentifier("quick-profile-search")
                Text("esc").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 4).glassCard(cornerRadius: 5)
            }.padding(.horizontal, 22).frame(height: 72)
            Divider().opacity(0.25)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        if results.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: model.profiles.isEmpty ? "doc.badge.plus" : "magnifyingglass")
                                    .font(.system(size: 28, weight: .light))
                                Text(model.profiles.isEmpty ? "尚未导入配置" : "没有匹配的配置")
                                Text(model.profiles.isEmpty ? "在主窗口导入 .ovpn 后即可快速连接" : "试试其他名称、分组或文件名")
                                    .font(.system(size: 12))
                            }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 65)
                        }
                        ForEach(results) { profile in
                            Button { onSelect(profile.id) } label: { row(profile) }
                                .buttonStyle(.plain).id(profile.id)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(profile.name)
                                .accessibilityValue([profile.group, profile.isFavorite ? "已收藏" : "未收藏",
                                    model.connected && model.activeProfileID == profile.id ? "已连接" : "未连接",
                                    state.selectedID == profile.id ? "已选择" : "未选择"].joined(separator: "，"))
                                .accessibilityHint("选择配置；使用底部按钮连接或查看当前连接")
                                .accessibilityAddTraits(state.selectedID == profile.id ? .isSelected : [])
                        }
                    }.padding(10)
                }
                .onChange(of: state.selectedID) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
            }
            Divider().opacity(0.25)
            if let id = state.pendingSwitchID, let target = model.profiles.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("将断开当前 VPN，再连接“\(target.name)”。").font(.system(size: 13)).lineLimit(2)
                    HStack {
                        Button("取消", action: onCancel).buttonStyle(ReferenceSecondaryButton())
                        Spacer()
                        Button("断开并连接", action: onConfirm).buttonStyle(ReferencePrimaryButton())
                    }
                }.padding(16)
            } else {
                HStack(spacing: 10) {
                    Text("↑↓ 选择 · ↵ 打开").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("主窗口", action: onOpenMain).buttonStyle(ReferenceQuietButton())
                    Button(actionTitle, action: onActivate).buttonStyle(ReferencePrimaryButton())
                        .disabled(action == .blocked)
                }.padding(.horizontal, 18).frame(height: 64)
            }
        }
        .frame(width: 560, height: 460)
        .background(GlassAtmosphere())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.75))
        .preferredColorScheme(.light)
        .onAppear { searchFocused = true }
        .onChange(of: state.query) { _ in onNormalize() }
        .onChange(of: model.profiles) { _ in onNormalize() }
    }
    private func row(_ profile: VPNProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.isFavorite ? "star.fill" : "network")
                .font(.system(size: 18)).foregroundStyle(GlassPalette.blue).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(profile.group + " · " + profile.sourceFilename)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.connected && model.activeProfileID == profile.id {
                Label("已连接", systemImage: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(.green)
            } else { Text(profile.mode.rawValue).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .foregroundStyle(GlassPalette.ink).padding(.horizontal, 12).frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 10).fill(state.selectedID == profile.id ? GlassPalette.blue.opacity(0.13) : .clear))
        .contentShape(Rectangle())
    }
}
