import SwiftUI
import VPNNavigatorCore

struct NetworkDiagnosticsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var address = "223.5.5.5"
    @State private var actualPath = ""
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
}
