import SwiftUI
import VPNNavigatorCore

struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = "223.5.5.5"
    @State private var hostname = "www.apple.com"
    @State private var port = "443"
    @State private var selectedTab: DiagnosticTab = .connection
    @State private var local: LocalNetworkSnapshot?
    @State private var tcp: TCPProbeResult?
    @State private var dnsAnswer = ""
    @State private var traceAnswer = ""
    @State private var ping: PingSummary?
    @State private var error = ""
    @State private var localError = ""
    @State private var checking = false
    @State private var showingTarget = false
    @State private var work: Task<Void, Never>?
    @State private var attempt = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection

    private enum DiagnosticTab: String, CaseIterable, Identifiable {
        case connection = "连接测试", dns = "DNS 解析", routing = "路由追踪", latency = "延迟测试"
        var id: String { rawValue }
    }
    private var ipv6Description: String {
        guard let local else { return L10n.text("尚未取得 IPv6 路由状态") }
        switch local.health.ipv6Safety {
        case .noDefaultRoute: return L10n.text("未发现 IPv6 默认路由")
        case .tunnelOnly: return L10n.text("发现隧道路由，归属仍需核验")
        case .physicalBypass: return L10n.text("发现物理网络 IPv6 默认路由")
        case .unknown: return L10n.text("无法确认 IPv6 路由状态")
        }
    }
    private var statusTitle: String {
        if checking { return L10n.text("正在进行实际探测…") }
        if !error.isEmpty { return L10n.text("本次探测未成功") }
        switch selectedTab {
        case .connection: return tcp?.summary ?? L10n.text("等待连接探测")
        case .dns: return dnsAnswer.isEmpty ? L10n.text("等待系统解析") : L10n.text("已收到系统解析结果")
        case .routing: return traceAnswer.isEmpty ? L10n.text("等待路由追踪") : L10n.text("追踪完成，最多 8 跳")
        case .latency: return ping.map { $0.received > 0 ? L10n.text("已收到 ICMP 响应") : L10n.text("目标未响应 ICMP") } ?? L10n.text("等待延迟探测")
        }
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    WorkspaceHeading(title: L10n.text("网络诊断"), subtitle: L10n.text("以真实探测核对连接、解析、路径和延迟"), symbol: "waveform.path.ecg")
                    Spacer()
                    Button(L10n.text("公网出口…")) { cancel(); model.showingPublicEgress = true }.buttonStyle(ReferenceSecondaryButton()).disabled(!model.canStartEgressProbe)
                }
                HStack(spacing: 14) {
                    HStack(spacing: 2) {
                        ForEach(DiagnosticTab.allCases) { tab in
                            Button { selectedTab = tab } label: {
                                Text(L10n.text(tab.rawValue)).font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))
                                    .foregroundStyle(selectedTab == tab ? GlassPalette.blue : GlassPalette.ink.opacity(0.58))
                                    .frame(maxWidth: .infinity).frame(height: 34)
                                    .background {
                                        if selectedTab == tab {
                                            RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.5))
                                                .matchedGeometryEffect(id: "diagnostic-selection", in: selection)
                                        }
                                    }
                            }.buttonStyle(ReferenceQuietButton())
                                .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                                .accessibilityValue(selectedTab == tab ? L10n.text("已选择") : L10n.text("未选择"))
                        }
                    }.referenceSegments().frame(width: 420)
                        .animation(GlassMotion.selection(reduceMotion), value: selectedTab)
                    Spacer(minLength: 0)
                    Button(L10n.text("一键排障…")) { cancel(); model.showingTroubleshooting = true }.buttonStyle(ReferenceSecondaryButton())
                    Button {
                        if checking { cancel() } else { run() }
                    } label: { Label(checking ? L10n.text("取消探测") : L10n.text("重新检查"), systemImage: checking ? "xmark" : "arrow.clockwise") }
                        .buttonStyle(ReferenceSecondaryButton())
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label(L10n.text(selectedTab.rawValue), systemImage: "waveform.path.ecg")
                                .font(.system(size: 18, weight: .semibold))
                            Spacer()
                            Button { showingTarget = true } label: { Image(systemName: "ellipsis").foregroundStyle(GlassPalette.blue) }
                                .buttonStyle(ReferenceQuietButton()).help(L10n.text("设置诊断目标")).accessibilityLabel(L10n.text("设置诊断目标"))
                                .popover(isPresented: $showingTarget) { targetEditor }
                        }
                        probeContent
                        Spacer(minLength: 0)
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 9) {
                                if checking { ProgressView().controlSize(.small) }
                                else { Image(systemName: !error.isEmpty || tcp?.reachable == false && selectedTab == .connection ? "exclamationmark.circle" : "info.circle") }
                                Text(statusTitle).font(.system(size: 15, weight: .semibold))
                            }
                            Text(error.isEmpty ? L10n.text("结果仅表示所测目标的状态，不等同于 VPN 安全或无泄漏证明。") : error)
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    }.padding(18)
                        .frame(width: max(280, (geometry.size.width - 62) * 0.59))
                        .frame(maxHeight: .infinity).glassCard(cornerRadius: 18)
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 16) {
                            Label(L10n.text("当前系统路由"), systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 18, weight: .semibold))
                            routeStep(L10n.text("本机出口"), local?.health.ipv4DefaultInterface ?? L10n.text("未取得"), final: false)
                            routeStep(L10n.text("目标网关"), local?.gateway.isEmpty == false ? local!.gateway : L10n.text("未取得"), final: false)
                            routeStep(L10n.text("目的地址"), address, final: true)
                            if !localError.isEmpty {
                                Text(localError).font(.system(size: 12)).foregroundStyle(.orange)
                            }
                            Spacer(minLength: 0)
                        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).glassCard()
                        VStack(alignment: .leading, spacing: 7) {
                            Label(L10n.text("IPv6 路由检查"), systemImage: "exclamationmark.circle")
                                .font(.system(size: 16, weight: .semibold))
                            Text(ipv6Description).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text(L10n.text("此检查不会修改 IPv6 或防火墙。"))
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 112).glassCard()
                    }.frame(maxWidth: .infinity)
                }.frame(height: 430)
                Spacer(minLength: 0)
            }.padding(.horizontal, GlassLayout.pageInset).padding(.top, GlassLayout.pageTop).padding(.bottom, 20)
        }
        .onAppear { if !ProcessInfo.processInfo.arguments.contains("--vpnnav-ui-demo-snapshot") { run() } }
        .onChange(of: selectedTab) { _ in run() }
        .onDisappear { cancel() }
    }
    @ViewBuilder private var probeContent: some View {
        switch selectedTab {
        case .connection:
            VStack(spacing: 0) {
                resultRow(L10n.text("本机接口"), subtitle: L10n.text("系统默认 IPv4 出口"), value: local?.health.ipv4DefaultInterface ?? L10n.text("未取得"))
                resultRow(L10n.text("目标路由"), subtitle: L10n.text("系统路由表的实际接口"), value: local?.interface ?? L10n.text("未取得"))
                resultRow(L10n.text("DNS 配置"), subtitle: L10n.text("系统解析器数量"), value: local.map { L10n.format("{0} 个", [String(describing: $0.health.resolverCount)]) } ?? L10n.text("未取得"))
                resultRow("TCP \(port)", subtitle: L10n.format("{0} 的端口连接", [String(describing: address)]), value: tcp.map { $0.reachable ? "\(Int($0.milliseconds)) ms" : L10n.text("未连通") } ?? L10n.text("等待结果"))
            }.padding(.horizontal, 10).background(Color.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        case .dns:
            Text(hostname).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
            resultText(dnsAnswer.isEmpty ? L10n.text("切换到此页会向系统解析器发起实际查询。") : dnsAnswer)
        case .routing:
            Text(L10n.format("{0} · 每跳一个探测，最多 8 跳", [String(describing: address)]))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            resultText(traceAnswer.isEmpty ? L10n.text("追踪中或尚无返回；* 表示该跳未响应。") : traceAnswer)
        case .latency:
            if let ping {
                HStack(spacing: 26) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("平均延迟")).foregroundStyle(.secondary)
                        Text(ping.averageMilliseconds.map { String(format: "%.1f ms", $0) } ?? "—").font(.system(size: 30, weight: .medium))
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("丢包率")).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", ping.loss)).font(.system(size: 30, weight: .medium))
                    }
                }.padding(.vertical, 25)
                Text(L10n.format("{0} · 已收到 {1}/3 个 ICMP 响应", [String(describing: address), String(describing: ping.received)]))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            } else { resultText(L10n.format("向 {0} 发出 3 个 ICMP 探测，数据来自系统 ping。", [String(describing: address)])) }
            Text(L10n.text("目标禁用 ICMP 时也可能不响应，不能据此认定 VPN 故障。"))
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private func resultText(_ text: String) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
        }.frame(maxWidth: .infinity).frame(height: 220)
            .background(Color.white.opacity(0.20), in: RoundedRectangle(cornerRadius: 12))
    }
    private func resultRow(_ title: String, subtitle: String, value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 15, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(value).font(.system(size: 13)).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(height: 61)
    }
    private func routeStep(_ title: String, _ value: String, final: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(GlassPalette.blue).frame(width: 10, height: 10)
                Rectangle().fill(final ? .clear : GlassPalette.blue.opacity(0.3)).frame(width: 1, height: 35)
            }.padding(.top, 4)
            VStack(alignment: .leading, spacing: 5) {
                Text(value).font(.system(size: 15)).lineLimit(1)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
    private var targetEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("诊断目标")).font(.headline)
            TextField(L10n.text("目标 IPv4／IPv6"), text: $address).textFieldStyle(.plain).referenceInput()
            TextField(L10n.text("TCP 端口"), text: $port).textFieldStyle(.plain).referenceInput()
            TextField(L10n.text("DNS 查询域名"), text: $hostname).textFieldStyle(.plain).referenceInput()
            Button(L10n.text("应用并检查")) { showingTarget = false; run() }.buttonStyle(ReferencePrimaryButton())
                .disabled(IPAddress.canonical(address) == nil || UInt16(port).map { $0 > 0 } != true || !DiagnosticTargetPolicy.validHostname(hostname))
        }.padding(18).frame(width: 300)
    }
    private func cancel() {
        attempt = UUID(); work?.cancel(); work = nil; checking = false
    }
    private func run() {
        cancel()
        guard IPAddress.canonical(address) != nil, let portNumber = UInt16(port), portNumber > 0,
              DiagnosticTargetPolicy.validHostname(hostname) else { error = ProbeError.invalidTarget.localizedDescription; return }
        let token = UUID(); attempt = token
        let tab = selectedTab, target = address, name = hostname
        checking = true; error = ""; localError = ""
        tcp = nil; dnsAnswer = ""; traceAnswer = ""; ping = nil
        work = Task {
            do {
                let snapshot = try await NetworkProbes.localSnapshot(target: target)
                guard attempt == token else { return }; local = snapshot
            } catch {
                guard attempt == token else { return }; local = nil
                localError = L10n.text("未能读取完整本机网络状态。")
            }
            do {
                try Task.checkCancellation()
                switch tab {
                case .connection:
                    let value = try await NetworkProbes.tcp(target, port: portNumber)
                    guard attempt == token else { return }; tcp = value
                case .dns:
                    let value = try await NetworkProbes.dns(name)
                    guard attempt == token else { return }; dnsAnswer = value
                case .routing:
                    let value = try await NetworkProbes.trace(target)
                    guard attempt == token else { return }; traceAnswer = value
                case .latency:
                    let value = try await NetworkProbes.ping(target)
                    guard attempt == token else { return }; ping = value
                }
            } catch is CancellationError { /* Selection changes cancel old work. */ }
            catch {
                guard attempt == token else { return }
                self.error = error.localizedDescription
            }
            if attempt == token { checking = false; work = nil }
        }
    }
}
