import SwiftUI
import VPNNavigatorCore

@MainActor
struct CustomRoutingEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: VPNProfile
    @State private var draft: [CustomRouteRule]
    @State private var cidr = ""
    @State private var action: CustomRouteAction = .vpn
    @State private var issue = ""
    init(profile: VPNProfile) { self.profile = profile; _draft = State(initialValue: profile.customRules) }
    private func replace(_ next: [CustomRouteRule]) {
        do { draft = try CustomRuleSet(next).rules; issue = "" } catch { issue = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("自定义分流规则").font(.system(size: 23, weight: .bold))
            Text(profile.name + " · 仅作用于此配置的全局／规则模式，下次连接生效。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("IPv4 或网段，如 10.66.0.0/16", text: $cidr).textFieldStyle(.plain).referenceInput()
                Picker("路径", selection: $action) { ForEach(CustomRouteAction.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 105)
                Button("添加") {
                    replace(draft + [CustomRouteRule(cidr: cidr, action: action)])
                    if issue.isEmpty { cidr = "" }
                }.buttonStyle(ReferenceSecondaryButton()).disabled(cidr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count >= 128)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(draft) { rule in
                        HStack {
                            Toggle(isOn: Binding(get: { draft.first { $0.id == rule.id }?.enabled ?? false }, set: { enabled in
                                var next = draft; if let index = next.firstIndex(where: { $0.id == rule.id }) { next[index].enabled = enabled }; replace(next)
                            })) { Text(rule.cidr).font(.system(size: 13, design: .monospaced)) }.toggleStyle(.checkbox)
                            Spacer()
                            Text(rule.action.title).font(.system(size: 13)).foregroundStyle(rule.action == .vpn ? GlassPalette.blue : .secondary)
                            Button { replace(draft.filter { $0.id != rule.id }) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).help("删除此规则")
                        }.padding(12).glassCard(cornerRadius: 10)
                    }
                    if draft.isEmpty { Text("尚无自定义规则，继续使用地区规则和默认路由。").font(.system(size: 13)).foregroundStyle(.secondary).padding(24) }
                }.padding(2)
            }.frame(height: 245)
            Text("最多 128 条；启用规则不能重叠。服务器端点和当前局域网受保护，冲突会拒绝连接。支持 /8–/32；IPv6、域名和按应用分流暂不支持。可迁移 .ovpn 不包含这些应用内策略，路由预览可导出静态结果。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !issue.isEmpty { Text(issue).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("\(draft.filter(\.enabled).count) 条启用 / \(draft.count) 条保存").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(ReferenceSecondaryButton()).disabled(model.profileMetadataInProgress)
                Button("保存规则") {
                    Task { if let error = await model.saveCustomRules(for: profile.id, original: profile.customRules, draft: draft) { issue = error } else { dismiss() } }
                }.buttonStyle(ReferencePrimaryButton()).disabled(!model.canEditCustomRules(profile.id))
            }
        }.padding(24).frame(width: 680).background(GlassAtmosphere()).interactiveDismissDisabled(model.profileMetadataInProgress)
    }
}

@MainActor
struct RouteExplanationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var ip = "1.1.1.1"
    @State private var live = false
    @State private var decision: RouteExplanation?
    @State private var observed: RouteLookupResult?
    @State private var issue = ""
    @State private var checking = false
    @State private var work: Task<Void, Never>?
    @State private var generation = UUID()
    private let service = RoutingInspectionService.live
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("路由解释").font(.system(size: 23, weight: .bold))
            Text("配置预览仅计算规则；当前连接核验会读取助手保存的实际策略与系统路由，不发送探测数据。")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("核验当前已连接会话（与左侧选择无关）", isOn: $live).disabled(!model.connected || checking)
                .onChange(of: live) { _ in clear() }
            HStack {
                TextField("目标 IPv4", text: $ip).textFieldStyle(.plain).referenceInput().disabled(checking)
                Button(checking ? "核验中…" : "解释路径") { inspect() }.buttonStyle(ReferencePrimaryButton())
                    .disabled(checking || IPv4CIDR.parseAddress(ip) == nil)
            }
            if let decision {
                VStack(alignment: .leading, spacing: 12) {
                    Text(decision.path.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(GlassPalette.blue)
                    Text(decision.reason).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    if let prefix = decision.matchedPrefix { Text("命中前缀：" + prefix).font(.system(size: 13, design: .monospaced)) }
                    if let observed {
                        Text("实际接口：" + (observed.observedInterface.isEmpty ? "未知" : observed.observedInterface))
                        Text("实际网关：" + (observed.observedGateway.isEmpty ? "未取得" : observed.observedGateway))
                        Text(observed.matchesExpected.map { $0 ? "本次采样与预期路径一致" : "实际路径与预期不一致，请排查其它路由或 VPN" } ?? "系统管理路径，仅展示观察值")
                            .foregroundStyle(observed.matchesExpected == false ? Color.orange : Color.secondary)
                    } else {
                        Text("预览配置：" + (model.selected?.name ?? "未选择") + "；未纳入服务器端点、当前局域网及其它系统路由。")
                            .foregroundStyle(.secondary)
                    }
                }.font(.system(size: 13)).padding(16).frame(maxWidth: .infinity, alignment: .leading).glassCard()
            }
            if !issue.isEmpty { Text(issue).font(.system(size: 13)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("结果仅对所选地址及采样时刻有效，不代表所有流量或 DNS 均已通过 VPN。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { if checking { ProgressView().controlSize(.small) }; Spacer(); Button("关闭") { dismiss() }.buttonStyle(ReferenceSecondaryButton()) }
        }.padding(24).frame(width: 640).background(GlassAtmosphere())
            .onChange(of: model.activeRoutingIdentity) { _ in if live { clear(); issue = "会话状态改变，请重新核验。" } }
            .onChange(of: model.selectedID) { _ in if !live { clear() } }
            .onChange(of: model.profiles) { _ in if !live { clear() } }
            .onChange(of: ip) { _ in if !checking { decision = nil; observed = nil; issue = "" } }
            .onDisappear { clear() }
            .onAppear {
                if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
                   ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot"),
                   ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-route-explanation-snapshot") { ip = "9.9.9.9"; inspect() }
            }
    }
    private func clear() { generation = UUID(); work?.cancel(); work = nil; checking = false; decision = nil; observed = nil; issue = "" }
    private func inspect() {
        clear(); let token = UUID(); generation = token; checking = true
        let target = ip, actual = live, profile = model.selected, country = model.rules
        work = Task {
            defer { if generation == token { checking = false; work = nil } }
            do {
                if actual {
                    guard let report = await service.snapshot() else { throw ProbeError.commandFailed }
                    let request = try RouteLookupRequest(report: report, ip: target)
                    let result = try await service.verifiedLookup(request)
                    guard generation == token, !Task.isCancelled else { return }; decision = result.decision; observed = result
                } else {
                    guard let profile else { issue = "请先选择配置。"; return }
                    let preview = try RouteExplanation.decide(ip: target, mode: profile.mode, country: country, custom: CustomRuleSet(profile.customRules))
                    guard generation == token else { return }; decision = preview
                }
            } catch { if generation == token { issue = "未取得可核验结果：" + error.localizedDescription } }
        }
    }
}

@MainActor
struct OneClickTroubleshootingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var report = TroubleshootingModel()
    @State private var target = "1.1.1.1"
    @State private var hostname = "www.apple.com"
    @State private var port = "443"
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("一键排障").font(.system(size: 23, weight: .bold))
            Text("检查活动配置，未连接时检查当前选择。点击开始后会读取本机与助手状态，并向下面的目标发起 TCP 和系统 DNS 查询；不上传配置、凭据或原始日志，不修改网络设置。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("目标 IPv4", text: $target).textFieldStyle(.plain).referenceInput()
                TextField("TCP 端口", text: $port).textFieldStyle(.plain).referenceInput().frame(width: 95)
                TextField("查询域名", text: $hostname).textFieldStyle(.plain).referenceInput()
            }.disabled(report.running)
            HStack {
                if report.running { ProgressView().controlSize(.small) }
                Text(report.status).font(.system(size: 13, weight: .medium))
                Spacer()
                Button(report.running ? "取消检查" : "开始检查") {
                    if report.running { report.cancel() }
                    else if let value = UInt16(port) { report.start(model: model, target: target, port: value, hostname: hostname) }
                }.buttonStyle(ReferencePrimaryButton())
                    .disabled(!report.running && (IPv4CIDR.parseAddress(target) == nil || UInt16(port).map { $0 > 0 } != true || !DiagnosticTargetPolicy.validHostname(hostname)))
            }
            if report.stale { Text("会话或策略在检查期间改变；已显示结果是过程采样，请重新检查。").font(.system(size: 12)).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(report.checks) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.severity == .pass ? "checkmark.circle.fill" : item.severity == .failure ? "xmark.circle.fill" : "info.circle")
                                .foregroundStyle(item.severity == .pass ? Color.green : item.severity == .failure || item.severity == .warning ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).font(.system(size: 14, weight: .semibold))
                                Text(item.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                if !item.suggestion.isEmpty { Text("建议：" + item.suggestion).font(.system(size: 12)) }
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).glassCard(cornerRadius: 12)
                    }
                    if report.checks.isEmpty { Text("结果将在这里逐项显示。可取消，整体检查最多 30 秒。").font(.system(size: 13)).foregroundStyle(.secondary).padding(18) }
                }.padding(2)
            }.frame(height: 350)
            HStack {
                Text("结果只代表所测目标，不提供 VPN 安全或无泄漏证明。").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { report.cancel(); dismiss() }.buttonStyle(ReferenceSecondaryButton())
            }
        }.padding(24).frame(width: 740).background(GlassAtmosphere())
            .onChange(of: model.activeRoutingIdentity) { _ in report.invalidateSession() }
            .onChange(of: model.selectedID) { _ in if !model.connected { report.invalidateSession() } }
            .onChange(of: model.profiles) { _ in if !model.connected { report.invalidateSession() } }
            .onDisappear { report.cancel() }
            .onAppear { report.showSnapshotIfRequested() }
    }
}
