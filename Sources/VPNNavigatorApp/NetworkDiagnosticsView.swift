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
    @State private var showingTarget = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var diagnosticSelection

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
        GeometryReader { geometry in
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                Text("网络诊断").font(.system(size: ReferenceType.pageTitle, weight: .bold))
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    ForEach(DiagnosticTab.allCases) { tab in
                        Button { selectedTab = tab } label: {
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))
                                .foregroundStyle(selectedTab == tab ? GlassPalette.blue : GlassPalette.ink.opacity(0.58))
                                .frame(maxWidth: .infinity).frame(height: 34)
                                .background {
                                    if selectedTab == tab {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(Color.white.opacity(0.50))
                                            .matchedGeometryEffect(id: "diagnostic-selection", in: diagnosticSelection)
                                    }
                                }
                        }.buttonStyle(.plain)
                    }
                }
                .referenceSegments().frame(width: 420)
                .animation(GlassMotion.selection(reduceMotion), value: selectedTab)
                .padding(.trailing, 25)
            }.frame(height: 56)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        panelTitle(selectedTab == .dns ? "DNS 解析" : selectedTab == .routing ? "IPv4 路由检查" : selectedTab == .latency ? "延迟测试" : "IPv4 连接测试")
                        Spacer(minLength: 0)
                        Button { showingTarget = true } label: {
                            Image(systemName: "ellipsis").font(.system(size: 16)).foregroundStyle(GlassPalette.blue)
                        }
                        .buttonStyle(.plain).help("诊断目标与重新检查")
                        .popover(isPresented: $showingTarget) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("诊断目标").font(.headline)
                                TextField("目标 IPv4 地址", text: $address).textFieldStyle(.plain).referenceInput()
                                Button(checking ? "检查中…" : "开始检查") { runDiagnostics(); showingTarget = false }
                                    .buttonStyle(ReferencePrimaryButton())
                                    .disabled(checking || IPv4CIDR.parseAddress(address) == nil)
                            }.padding(18).frame(width: 280)
                        }
                    }
                    if selectedTab == .latency {
                        Text("真实延迟测量尚未接入。")
                            .font(.system(size: 15)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                    } else {
                        VStack(spacing: 0) {
                            if selectedTab == .connection {
                                diagnosticRow("本机网络", subtitle: "默认 IPv4 出口接口", value: health?.ipv4DefaultInterface ?? "尚未检查", checked: health?.ipv4DefaultInterface != nil)
                            }
                            if selectedTab == .connection || selectedTab == .routing {
                                diagnosticRow("网络连接", subtitle: "目标 IP 的路由网关", value: targetGateway.isEmpty ? "未查询" : targetGateway, checked: !targetGateway.isEmpty)
                                diagnosticRow("目标路由", subtitle: "系统路由表查询", value: targetInterface.isEmpty ? "未查询" : targetInterface, checked: !targetInterface.isEmpty)
                            }
                            if selectedTab == .connection || selectedTab == .dns {
                                diagnosticRow("DNS 解析器", subtitle: "系统 DNS 配置", value: health.map { "\($0.resolverCount) 个解析器" } ?? "尚未检查", checked: (health?.resolverCount ?? 0) > 0)
                            }
                        }
                        .padding(.horizontal, 9)
                        .background(Color.white.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer(minLength: 0)
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: actualPath.isEmpty ? "info.circle.fill" : "checkmark.circle.fill")
                            .font(.system(size: 35)).foregroundStyle(actualPath.isEmpty ? Color.orange : Color.green)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(actualPath.isEmpty ? "等待连接检查" : "本机路由已读取")
                                .font(.system(size: 17, weight: .semibold))
                            Text(actualPath.isEmpty ? "检查本机连接与路由状态" : "仅表示路由查询成功，不代表 VPN 已连接。")
                                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(actualPath.isEmpty ? GlassPalette.ink : Color.green)
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(18)
                .frame(width: max(280, (geometry.size.width - 54) * 0.61))
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .glassCard(cornerRadius: 18)
                VStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        panelTitle("当前路由路径")
                        VStack(alignment: .leading, spacing: 0) {
                            routeStep("本机出口", value: health?.ipv4DefaultInterface ?? "未检测", index: 0)
                            routeStep("目标网关", value: targetGateway.isEmpty ? "未检测" : targetGateway, index: 1)
                            routeStep("目的地址", value: address, index: 2)
                        }
                        Spacer(minLength: 0)

                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .glassCard(cornerRadius: 18)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("IPv6 连接（预览）").font(.system(size: 16, weight: .semibold))
                            Text(ipv6Description).font(.system(size: 12)).foregroundStyle(.secondary)
                            Text("仅检查路由，未实现 IPv6 分流。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 100).glassCard(cornerRadius: 18)
                }.frame(maxWidth: .infinity)
            }.frame(height: 350)
            Spacer(minLength: 0)
            if !healthError.isEmpty {
                Label(healthError, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, GlassLayout.pageInset)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .onAppear { if health == nil { runDiagnostics() } }
        }
    }

    private func panelTitle(_ title: String) -> some View {
        HStack(spacing: 9) {
            GlassIcon(symbol: "square.inset.filled", size: 28)
            Text(title).font(.system(size: 18, weight: .semibold))
        }
    }

    private func diagnosticRow(_ title: String, subtitle: String, value: String, checked: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 20)).foregroundStyle(checked ? Color.green : .secondary)
                .frame(width: 24)
            Text(title).font(.system(size: 16)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 13)).foregroundStyle(GlassPalette.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
        }.frame(height: 42).help(subtitle)
    }

    private func routeStep(_ title: String, value: String, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(GlassPalette.blue).frame(width: 11, height: 11)
                Rectangle().fill(index == 2 ? Color.clear : GlassPalette.blue.opacity(0.45)).frame(width: 2, height: 33)
            }.padding(.top, 5)
            Text(value).font(.system(size: 16)).foregroundStyle(GlassPalette.ink.opacity(0.80)).lineLimit(1)
            Spacer(minLength: 0)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }.frame(height: 44).accessibilityElement(children: .combine)
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

