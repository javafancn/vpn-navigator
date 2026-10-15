import SwiftUI
import VPNNavigatorCore

struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = "223.5.5.5"
    @State private var actualPath = ""
    @State private var networkSummary = "Not checked"
    var body: some View {
        Form {
            Section("IPv4 route diagnosis") {
                HStack {
                    TextField("Destination IPv4", text: $address)
                    Button("Inspect") { inspect() }
                        .disabled(IPv4CIDR.parseAddress(address) == nil)
                }
                if let decision = IPDiagnostics.decide(
                    ip: address, mode: model.selected?.mode ?? .original, rules: model.rules
                ) {
                    LabeledContent("Expected path", value: decision.expected.rawValue)
                    Text(decision.reason).foregroundStyle(.secondary)
                }
                Text(actualPath.isEmpty ? "No route checked" : actualPath)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
            Section("Local network health") {
                Button("Inspect IPv6 and DNS") { inspectHealth() }
                Text(networkSummary)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                Text("Only counts and interface names are shown. Private DNS domains and server addresses are not displayed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Network protections") {
                Text("IPv4 rules do not control IPv6. Check macOS IPv6 routes and DNS before relying on a split-tunnel.")
                    .foregroundStyle(.orange)
                Text("Route output comes from macOS and does not prove the remote exit IP. A real VPN connection is required for end-to-end testing.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Network Diagnostics")
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
