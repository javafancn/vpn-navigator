import SwiftUI
import VPNNavigatorCore

struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = "223.5.5.5"
    @State private var actualPath = ""
    @State private var networkSummary = "尚未检查"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WorkspaceHeading(title: "网络诊断",
                    subtitle: "查看当前 macOS 路由与 DNS 摘要，不上传隐私数据",
                    symbol: "waveform.path.ecg")
                HStack(alignment: .top, spacing: 13) {
                    VPNPanel("IPv4 路由检查", symbol: "point.topleft.down.curvedto.point.bottomright.up") {
                        HStack(spacing: 10) {
                            TextField("输入 IPv4 地址", text: $address)
                                .textFieldStyle(.roundedBorder)
                            Button("检查路径") { inspect() }
                                .buttonStyle(.borderedProminent)
                                .disabled(IPv4CIDR.parseAddress(address) == nil)
                        }
                        if let decision = IPDiagnostics.decide(
                            ip: address, mode: model.selected?.mode ?? .original, rules: model.rules
                        ) {
                            LabeledContent("预期路径", value: decision.expected.rawValue)
                            Text(decision.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(actualPath.isEmpty ? "尚未查询实际路由" : actualPath)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    VPNPanel("本地网络健康", symbol: "heart.text.square") {
                        HStack {
                            Text("IPv6 默认路由、系统网卡与 DNS 解析器统计")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("检查 IPv6 / DNS") { inspectHealth() }
                        }
                        Text(networkSummary)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("仅展示接口名称和数量，不展示私有 DNS 域名或服务器地址。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    }
                VPNPanel("安全说明", symbol: "exclamationmark.shield") {
                    Label("IPv4 分流不等于 IPv6 保护", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("路由表检查无法验证远端公网出口 IP。此页面不提供真实延迟测试、测速或零泄漏认证。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(28).frame(maxWidth: 950, alignment: .leading)
        }
    }
    private func inspect() {
        guard IPv4CIDR.parseAddress(address) != nil else { return }
        let target = address
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["-n", "get", target]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self)
                let summary = output.components(separatedBy: .newlines)
                    .filter { $0.contains("gateway:") || $0.contains("interface:") }
                    .joined(separator: "\n")
                await MainActor.run {
                    actualPath = process.terminationStatus == 0 ? summary : "No route could be resolved."
                }
            } catch {
                await MainActor.run { actualPath = error.localizedDescription }
            }
        }
    }
    private func inspectHealth() {
        Task.detached {
            let v6 = DiagnosticCommands.read("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
            let defaultRoute = DiagnosticCommands.read("/sbin/route", ["-n", "get", "default"])
            let dns = DiagnosticCommands.read("/usr/sbin/scutil", ["--dns"])
            let summary = NetworkHealthSummary(
                ipv6Table: v6, defaultIPv4Route: defaultRoute, dnsSummary: dns)
            let risk: String
            switch summary.ipv6Safety {
            case .noDefaultRoute: risk = "No IPv6 default route detected"
            case .tunnelOnly: risk = "IPv6 tunnel route exists; full IPv6 safety is unverified"
            case .physicalBypass: risk = "IPv6 physical bypass detected"
            case .unknown: risk = "IPv6 safety could not be determined"
            }
            let output = "Default IPv4 interface: \(summary.ipv4DefaultInterface ?? "Unknown")\n" +
                "IPv6: \(risk)\n" +
                "DNS resolvers: \(summary.resolverCount)\n" +
                "DNS nameservers: \(summary.nameserverCount)"
            await MainActor.run { networkSummary = output }
        }
    }
}

private enum DiagnosticCommands {
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
            return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
        } catch { return "" }
    }
}
