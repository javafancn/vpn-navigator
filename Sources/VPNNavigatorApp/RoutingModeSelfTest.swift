import Foundation
import AppKit
import VPNNavigatorCore

@MainActor
enum RoutingModeSelfTest {
    final class Service {
        var report: SessionReport?
        var calls = 0
        var refuse = false
        var beforeApply: (() -> Void)?
        func apply(_ request: RoutingModeSwitchRequest, _ text: String) -> String {
            calls += 1
            beforeApply?()
            guard let old = report, request.matches(old) else { return "ERROR: stale fixture" }
            if refuse { return "ERROR: fixture route verification refused" }
            guard request.target != .chinaDirect || (try? RuleSet(text: text).routes.count) == 100,
                  request.target != .fullVPN || text.isEmpty else { return "ERROR: bad rules fixture" }
            report = SessionReport(state: .connected, message: "fixture", activeProfileID: old.activeProfileID,
                receivedBytes: old.receivedBytes, sentBytes: old.sentBytes, attemptID: old.attemptID,
                routingMode: request.target, routingRevision: UUID())
            return "Routing mode applied"
        }
    }
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-routing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.ovpn")
        try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n".write(to: file, atomically: true, encoding: .utf8)
        let service = Service()
        let storeRoot = root.appendingPathComponent("profiles")
        let model = AppModel(profileStoreRoot: storeRoot, routingModeService:
            RoutingModeService(snapshot: { service.report }, apply: { service.apply($0, $1) }))
        await model.importFile(file); model.clearImportReport(); model.message = nil
        guard let id = model.selectedID else { throw Failure.check }
        await model.setMode(.fullVPN)
        guard model.selected?.mode == .fullVPN, service.calls == 0 else { throw Failure.check }
        let attempt = UUID()
        service.report = SessionReport(state: .connected, message: "fixture", activeProfileID: id,
            receivedBytes: 12_345, sentBytes: 678, attemptID: attempt,
            routingMode: .fullVPN, routingRevision: UUID())
        model.applyVerifiedSessionReport(service.report!)
        model.rules = try RuleSet(text: (0..<100).map { "11.0.\($0).0/24" }.joined(separator: "\n"))
        var blockedExit = false
        let lifecycle = ApplicationLifecycle(); lifecycle.model = model
        service.beforeApply = { [weak model] in
            if let model {
                blockedExit = blockedExit || (!model.canQuit && model.routingModeSwitching &&
                    lifecycle.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
            }
        }
        await model.setMode(.chinaDirect)
        await model.setMode(.fullVPN)
        guard blockedExit, service.calls == 2, model.activeRoutingMode == .fullVPN,
              model.selected?.mode == .fullVPN, model.activeProfileID == id, model.connected,
              model.traffic?.receivedBytes == 12_345, model.traffic?.sentBytes == 678,
              !model.routingModeSwitching, !model.canSetRoutingMode(.original, for: id) else { throw Failure.check }
        service.refuse = true
        await model.setMode(.chinaDirect)
        guard service.calls == 3, model.activeRoutingMode == .fullVPN, model.selected?.mode == .fullVPN else { throw Failure.check }
        service.refuse = false; model.message = nil
        // A different revision of the same session must not receive this click.
        let old = service.report!
        service.report = SessionReport(state: .connected, message: "fixture", activeProfileID: id,
            receivedBytes: old.receivedBytes, sentBytes: old.sentBytes, attemptID: attempt,
            routingMode: .fullVPN, routingRevision: UUID())
        await model.setMode(.chinaDirect)
        guard service.calls == 3, model.selected?.mode == .fullVPN else { throw Failure.check }
        model.message = nil
        model.rules = nil
        await model.setMode(.chinaDirect)
        guard service.calls == 3 else { throw Failure.check }
        model.rules = try RuleSet(text: (0..<100).map { "11.0.\($0).0/24" }.joined(separator: "\n"))
        // A verified actual mode remains truthful when saving preferences fails.
        let index = storeRoot.appendingPathComponent("profiles.json"), backup = root.appendingPathComponent("index-backup.json")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: backup)
        await model.setMode(.chinaDirect)
        guard service.calls == 4, model.activeRoutingMode == .chinaDirect,
              model.selected?.mode == .fullVPN, model.message?.contains("保存失败") == true else { throw Failure.check }
        service.report = nil; model.message = nil
        await model.setMode(.fullVPN)
        guard model.activeRoutingMode == nil, model.displayedRoutingMode(for: id) == nil,
              !model.canQuit, service.calls == 4 else { throw Failure.check }
        print("PASS: production routing model round trip, session/traffic preservation, stale revision, missing rules, rejected switch, unverified snapshot and actual mode after preference failure; injected helper only.")
    }
    enum Failure: Error { case check }
}
