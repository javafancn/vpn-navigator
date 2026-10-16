import SwiftUI
import VPNNavigatorCore

/// Diagnostic cards mirror the visual reference while showing only real
/// information obtained from local macOS commands. Never invent latency,
/// throughput, successful checks, servers, or geographic destinations.
struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = "223.5.5.5"
    @State private var actualPath = ""
    @State private var targetGateway = ""
    @State private var targetInterface = ""
    @State private var health: NetworkHealthSummary?
    @State private var healthError = ""
    @State private var selectedTab: DiagnosticTab = .connection
    @State private var checking = false

    private enum DiagnosticTab: String, CaseIterable, Identifiable {
        case connection = "连接测试"
        case dns = "DNS 解析"
        case routing = "路由追踪"
        case latency = "延迟测试"
        var id: String { rawValue }
    }

    private var ipv6Description: String {
        guard let health else { return "尚未检测" }
        switch health.ipv6Safety {
        case .noDefaultRoute: return "无 IPv6 默认路由"
        case .tunnelOnly: return "发现 VPN 路由 · 安全性未核验"
        case .physicalBypass: return "发现物理网络 IPv6 旁路"
        case .unknown: return "无法确认 IPv6 路由"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GlassLayout.sectionSpacing) {
                HStack(alignment: .center, spacing: 10) {
                    WorkspaceHeading(title: "网络诊断", subtitle: "",
                        symbol: "waveform.path.ecg")
                    Spacer(minLength: 2)
                    HStack(spacing: 3) {
                        ForEach(DiagnosticTab.allCases) { tab in
                            Button {
                                selectedTab = tab
                            } label: {
                                Text(tab.rawValue)
                                    .font(.system(size: 11, weight: selectedTab == tab ?
                                                   .semibold : .medium))
                                    .foregroundStyle(selectedTab == tab ?
                                                     Color.white : GlassPalette.ink.opacity(0.68))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .background {
                                        if selectedTab == tab {
                                            RoundedRectangle(cornerRadius: 8)
                                                .fill(GlassPalette.blue.gradient)
                                                .shadow(color: GlassPalette.blue.opacity(0.20),
                                                        radius: 6, y: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(3)
                    .frame(width: 345)
                    .background(GlassSurface.sidebar.opacity(0.36),
                                in: RoundedRectangle(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(Color.white.opacity(0.70), lineWidth: 1)
                    }
                    .padding(.trailing, 26)
                }

                HStack(alignment: .top, spacing: 12) {
                    VPNPanel(selectedTab == .dns ? "DNS 解析" :
                             selectedTab == .routing ? "IPv4 路由检查" :
                             selectedTab == .latency ? "延迟测试" : "IPv4 连接测试",
                             symbol: "checkmark.circle") {
                        HStack(spacing: 8) {
                            TextField("目标 IPv4 地址", text: $address)
                                .textFieldStyle(.plain)
                                .referenceInput(height: 28)
                            Button(checking ? "检查中…" : "检查") { runDiagnostics() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(checking || IPv4CIDR.parseAddress(address) == nil)
                        }
                        .padding(.bottom, 2)

                        if selectedTab == .latency {
                            Label("尚未支持真实延迟测量，不能显示模拟的毫秒值。",
                                  systemImage: "info.circle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 10)
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                if selectedTab == .connection {
                                    diagnosticRow("本机网络", subtitle: "默认 IPv4 出口接口",
                                        value: health?.ipv4DefaultInterface ?? "尚未检查",
                                        checked: health?.ipv4DefaultInterface != nil)
                                    Divider().opacity(0.24)
                                }
                                if selectedTab == .connection || selectedTab == .routing {
                                    diagnosticRow("网关连接", subtitle: "目标 IP 的实际路由网关",
                                        value: targetGateway.isEmpty ? "未查询" : targetGateway,
                                        checked: !targetGateway.isEmpty)
                                    Divider().opacity(0.24)
                                    diagnosticRow("目标路由", subtitle: "系统路由表查询",
                                        value: targetInterface.isEmpty ? "未查询" : targetInterface,
                                        checked: !targetInterface.isEmpty)
                                    Divider().opacity(0.24)
                                }
                                if selectedTab == .connection || selectedTab == .dns {
                                    diagnosticRow("DNS 解析器", subtitle: "系统 scutil --dns",
                                        value: health.map { "\($0.resolverCount) 个解析器" } ??
                                               "尚未检查",
                                        checked: (health?.resolverCount ?? 0) > 0)
                                }
                            }
                            .padding(.horizontal, 10)
                            .background(Color.white.opacity(0.29),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(Color.white.opacity(0.41), lineWidth: 1)
                            }
                        }

                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: actualPath.isEmpty ?
                                  "info.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(actualPath.isEmpty ?
                                                 Color.orange : Color.green)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(actualPath.isEmpty ?
                                     "等待连接检查" : "本机路由已读取")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(actualPath.isEmpty ?
                                     "检查本机连接与路由状态" :
                                     "本机路由查询成功；不代表 VPN 已连接或不存在泄漏")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.green.opacity(actualPath.isEmpty ? 0.045 : 0.11),
                                    in: RoundedRectangle(cornerRadius: 12))
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 11) {
                        VPNPanel("当前路由路径",
                                 symbol: "point.3.connected.trianglepath.dotted") {
                            routeStep("本机出口接口",
                                value: health?.ipv4DefaultInterface ?? "未检测", index: 0)
                            routeStep("目标网关",
                                value: targetGateway.isEmpty ? "未检测" : targetGateway,
                                index: 1)
                            routeStep("目的地址", value: address, index: 2)
                            if let decision = IPDiagnostics.decide(
                                ip: address,
                                mode: model.selected?.mode ?? .original,
                                rules: model.rules) {
                                Divider().opacity(0.28)
                                Label("预期路径：\(decision.expected.rawValue)",
                                      systemImage: "info.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(GlassPalette.blue)
                                Text(decision.reason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        HStack(spacing: 11) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(.orange)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("IPv6 连接（预览）")
                                    .font(.system(size: 12, weight: .semibold))
                                Text(ipv6Description)
                                    .font(.system(size: 10))
                                    .foregroundStyle(health?.ipv6Safety == .noDefaultRoute ?
                                                     Color.green : Color.orange)
                                Text("仅核查本机路由，未实现 IPv6 分流。")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 15)
                    }
                    .frame(maxWidth: .infinity)
                }
                if !healthError.isEmpty {
                    Label(healthError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, GlassLayout.pageInset)
            .padding(.top, GlassLayout.pageTop)
            .padding(.bottom, 20)
            .frame(maxWidth: 1100, alignment: .topLeading)
        }
        .onAppear {
            if health == nil { runDiagnostics() }
        }
    }

    private func diagnosticRow(_ title: String, subtitle: String,
                               value: String, checked: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 16))
                .foregroundStyle(checked ? Color.green : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(checked ? Color.green : Color.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 9)
    }

    private func routeStep(_ title: String, value: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                Circle()
                    .fill(GlassPalette.blue)
                    .frame(width: 9, height: 9)
                if index != 2 {
                    Rectangle()
                        .fill(GlassPalette.blue.opacity(0.35))
                        .frame(width: 1, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func runDiagnostics() {
        guard IPv4CIDR.parseAddress(address) != nil, !checking else { return }
        checking = true
        let target = address
        Task.detached {
            let route = DiagnosticCommands.read("/sbin/route",
                                                 ["-n", "get", target])
            let gateway = DiagnosticCommands.field("gateway", in: route)
            let interface = DiagnosticCommands.field("interface", in: route)
            let summary = NetworkHealthSummary(
                ipv6Table: DiagnosticCommands.read("/usr/sbin/netstat",
                    ["-rn", "-f", "inet6"]),
                defaultIPv4Route: DiagnosticCommands.read("/sbin/route",
                    ["-n", "get", "default"]),
                dnsSummary: DiagnosticCommands.read("/usr/sbin/scutil", ["--dns"]))
            await MainActor.run {
                targetGateway = gateway ?? ""
                targetInterface = interface ?? ""
                actualPath = route
                health = summary
                healthError = route.isEmpty ? "系统未返回目标地址的路由信息。" : ""
                checking = false
            }
        }
    }
}

private enum DiagnosticCommands {
    static func field(_ key: String, in output: String) -> String? {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix(key + ":") })?
            .split(separator: ":", maxSplits: 1).last
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func read(_ executable: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return task.terminationStatus == 0 ?
                String(decoding: data, as: UTF8.self) : ""
        } catch {
            return ""
        }
    }
}
