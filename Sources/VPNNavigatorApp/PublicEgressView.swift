import SwiftUI
import VPNNavigatorCore

@MainActor
struct PublicEgressView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var checker = PublicEgressModel()
    @State private var ipv4 = true
    @State private var ipv6 = true
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(L10n.text("公网出口检测"), systemImage: "globe").font(.system(size: 23, weight: .bold))
            Text(L10n.text("点击开始后，向 ipify 查询所选地址族。服务方会看到本次请求的出口 IP；不发送配置、账号、证书或原始日志。结果只保留在当前窗口。"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Toggle("IPv4", isOn: $ipv4).disabled(checker.running); Toggle("IPv6", isOn: $ipv6).disabled(checker.running)
                Spacer()
                if checker.running { ProgressView().controlSize(.small) }
                Button(checker.running ? L10n.text("取消检测") : L10n.text("开始检测")) {
                    if checker.running { checker.cancel() }
                    else { checker.start(model: model, families: (ipv4 ? [.ipv4] : []) + (ipv6 ? [.ipv6] : [])) }
                }.buttonStyle(ReferencePrimaryButton()).disabled(!checker.running && ((!ipv4 && !ipv6) || !model.canStartEgressProbe))
            }.font(.callout)
            Text(checker.status).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(checker.rows) { row in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(row.family.title).font(.headline)
                                Spacer()
                                if let response = row.response { Text(String(format: "%.0f ms", response.milliseconds)).font(.caption).foregroundStyle(.secondary) }
                            }
                            if let response = row.response {
                                Text(response.address).font(.system(size: 19, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                                Label(row.assessment?.title ?? EgressPathAssessment.unknown.title,
                                    systemImage: row.assessment == .vpnRoute ? "checkmark.circle" : row.assessment == .mismatch ? "exclamationmark.triangle" : "info.circle")
                                    .font(.callout).foregroundStyle(row.assessment == .vpnRoute ? Color.green : row.assessment == .mismatch ? Color.orange : Color.secondary)
                                if let interface = row.interface { Text(L10n.text("采样接口：") + interface).font(.caption).foregroundStyle(.secondary) }
                                if response.usedProxy == true { Text(L10n.text("系统报告代理参与；该结果不能作为 VPN 路径依据。")).font(.caption).foregroundStyle(.orange) }
                                if response.cacheHit == true { Text(L10n.text("系统报告缓存响应；未将其作为当前路径证明。")).font(.caption).foregroundStyle(.orange) }
                            }
                            if let failure = row.failure { Label(failure.localizedDescription, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard(cornerRadius: 14)
                    }
                    if checker.rows.isEmpty {
                        Text(L10n.text("IPv4：api.ipify.org\nIPv6：api6.ipify.org\n仅手动检测；公网请求最多 8 秒，含路由核验整体最多 25 秒。"))
                            .font(.callout).foregroundStyle(.secondary).padding(20)
                    }
                }.padding(2)
            }.frame(height: 320)
            Text(L10n.text("接口是路由表的过程采样；响应耗时不是带宽或纯网络延迟。IPv6 查询失败不等于泄漏。此检查不验证 DNS 出口，也不提供全部流量或无泄漏证明；其他 TUN 软件仍可能影响路径。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                if let date = checker.checkedAt { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L10n.text("完成")) { checker.cancel(clear: true); dismiss() }.buttonStyle(ReferenceSecondaryButton())
            }
        }.padding(24).frame(width: 740).background(GlassAtmosphere())
            .onAppear { checker.showSnapshotIfRequested() }
            .onChange(of: model.egressContextIdentity) { _ in if checker.running || !checker.rows.isEmpty { checker.invalidate() } }
            .onDisappear { checker.cancel(clear: true) }
    }
}
