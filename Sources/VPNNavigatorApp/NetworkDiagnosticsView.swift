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
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    WorkspaceHeading(title: "网络诊断",
                        subtitle: "检查本机 IPv4 路由、DNS 与 IPv6 网络状态",
                        symbol: "waveform.path.ecg")
                    Spacer(minLength: 8)
                }

                HStack(spacing: 0) {
                    Picker("诊断类型", selection: $selectedTab) {
                        ForEach(DiagnosticTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    Spacer(minLength: 8)
                    Button {
                        runDiagnostics()
                    } label: {
                        Label(checking ? "正在检查" : "连接测试",
                              systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(checking || IPv4CIDR.parseAddress(address) == nil)
                }

                HStack(alignment: .top, spacing: 13) {
                    VPNPanel(selectedTab == .dns ? "DNS 状态" : "IPv4 连接测试",
                             symbol: "checkmark.shield") {
                        HStack(spacing: 9) {
                            TextField("目标 IPv4 地址", text: $address)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                            Button("检查") { runDiagnostics() }
                                .controlSize(.small)
                                .disabled(checking || IPv4CIDR.parseAddress(address) == nil)
                        }

                        Divider().opacity(0.4)
                        diagnosticRow("本机网络", subtitle: "默认 IPv4 出口接口",
                            value: health?.ipv4DefaultInterface ?? "尚未检查",
                            symbol: "desktopcomputer",
                            color: health?.ipv4DefaultInterface == nil ? .secondary : .green)
                        diagnosticRow("网络网关", subtitle: "目标 IP 的实际路由网关",
                            value: targetGateway.isEmpty ? "尚未查询" : targetGateway,
                            symbol: "network",
                            color: targetGateway.isEmpty ? .secondary : .green)
                        diagnosticRow("目标路由", subtitle: "系统 route -n get 检查",
                            value: targetInterface.isEmpty ? "尚未查询" : targetInterface,
                            symbol: "arrow.triangle.branch",
                            color: targetInterface.isEmpty ? .secondary : .green)
                        diagnosticRow("DNS 解析器", subtitle: "系统 scutil --dns",
                            value: health.map { "\($0.resolverCount) 个解析器" } ?? "尚未检查",
                            symbol: "globe",
                            color: health == nil ? .secondary : .green)
                        diagnosticRow("IPv6 路由", subtitle: "物理网络旁路检查",
                            value: ipv6Description,
                            symbol: "shield",
                            color: health == nil ? .secondary :
                                  health?.ipv6Safety == .noDefaultRoute ? .green : .orange)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 12) {
                        VPNPanel("当前路由路径", symbol: "point.topleft.down.curvedto.point.bottomright.up") {
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
                                Divider().opacity(0.4)
                                HStack(spacing: 6) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(GlassPalette.blue)
                                    Text("预期路径：\(decision.expected.rawValue)")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                Text(decision.reason)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        VPNPanel("安全提醒", symbol: "exclamationmark.shield") {
                            Text("路由表、DNS 和 IPv6 信息均来自本机系统命令；无法据此证明公网出口位置、实际延迟或零泄漏。")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !healthError.isEmpty {
                                Text(healthError)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .onAppear {
            if health == nil { runDiagnostics() }
        }
    }

    private func diagnosticRow(_ title: String, subtitle: String,
                               value: String, symbol: String,
                               color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(GlassPalette.blue)
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 6)
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
