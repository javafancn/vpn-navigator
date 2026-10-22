import Foundation
import VPNNavigatorCore

@MainActor
enum RoutingToolsSelfTest {
    final class State {
        var report: SessionReport?
        var staleLookup = false
        var slowDNS = false
        var dnsEntered = false
        func lookup(_ request: RouteLookupRequest) throws -> RouteLookupResult {
            guard let report, request.matches(report) else { throw RoutingModeSwitchError.stale }
            let decision = try RouteExplanation.decide(ip: request.ip, mode: request.mode, country: nil, custom: .empty)
            if staleLookup {
                self.report = SessionReport(state: .connected, message: "fixture", activeProfileID: report.activeProfileID,
                    receivedBytes: nil, sentBytes: nil, attemptID: UUID(), routingMode: request.mode, routingRevision: UUID())
            }
            return .init(request: request, decision: decision, expectedInterface: nil, observedInterface: "lo0", observedGateway: "127.0.0.1", matchesExpected: nil)
        }
    }
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else { throw Failure.check }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vpnnav-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.ovpn")
        try "client\ndev tun\nremote fixture.example 1194\n<ca>\nFAKE\n</ca>\n".write(to: source, atomically: true, encoding: .utf8)
        let model = AppModel(profileStoreRoot: root.appendingPathComponent("profiles"))
        await model.importFile(source); model.clearImportReport(); model.message = nil
        guard let original = model.selected else { throw Failure.check }
        let rules = [CustomRouteRule(cidr: "9.9.9.9", action: .direct), CustomRouteRule(cidr: "10.66.0.0/16", action: .vpn)]
        let saved = await model.saveCustomRules(for: original.id, original: [], draft: rules)
        guard saved == nil, let profile = model.selected, profile.customRules.first?.cidr == "9.9.9.9/32" else { throw Failure.check }
        let stale = await model.saveCustomRules(for: original.id, original: [], draft: [])
        guard stale != nil, model.selected?.customRules == profile.customRules else { throw Failure.check }
        await model.setMode(.fullVPN)
        guard model.selected?.customRules == profile.customRules else { throw Failure.check }
        let state = State()
        state.report = SessionReport(state: .connected, message: "fixture", activeProfileID: profile.id, receivedBytes: nil, sentBytes: nil,
            attemptID: UUID(), routingMode: .fullVPN, routingRevision: UUID(), customRuleDigest: try CustomRuleSet(profile.customRules).digest, customRuleCount: 2)
        model.applyVerifiedSessionReport(state.report!)
        guard !model.canEditCustomRules(profile.id), await model.saveCustomRules(for: profile.id, original: profile.customRules, draft: []) != nil,
              model.activeCustomRuleCount == 2 else { throw Failure.check }
        let server = try LoopbackProbeServer(); let port = try await server.listen(); defer { server.close() }
        let service = RoutingInspectionService(snapshot: { state.report }, lookup: { try state.lookup($0) },
            local: { _ in .init(gateway: "127.0.0.1", interface: "lo0", health: NetworkHealthSummary(ipv6Table: "", defaultIPv4Route: "interface: lo0", dnsSummary: "resolver #1\nnameserver[0]: 127.0.0.1")) },
            tcp: { try await NetworkProbes.tcp($0, port: $1) },
            dns: { name in state.dnsEntered = true; if state.slowDNS { try await Task.sleep(nanoseconds: 2_000_000_000) }; return try await NetworkProbes.dns(name) }, events: { [] })
        let request = try RouteLookupRequest(report: state.report!, ip: "127.0.0.1")
        _ = try await service.verifiedLookup(request)
        state.staleLookup = true
        do { _ = try await service.verifiedLookup(request); throw Failure.unexpectedSuccess } catch RoutingModeSwitchError.stale { }
        state.staleLookup = false
        let checker = TroubleshootingModel(service: service)
        checker.start(model: model, target: "127.0.0.1", port: port, hostname: "localhost")
        try await finished(checker)
        guard checker.checks.contains(where: { $0.id == "dns" && $0.severity == .pass }),
              checker.checks.contains(where: { $0.id == "tcp" && $0.severity == .pass }),
              checker.checks.contains(where: { $0.id == "route" && $0.severity == .info }) else { throw Failure.check }
        // Cancellation and the overall deadline cannot publish a late DNS result.
        state.slowDNS = true; state.dnsEntered = false
        checker.start(model: model, target: "127.0.0.1", port: port, hostname: "localhost")
        for _ in 0..<100 where !state.dnsEntered { try await Task.sleep(nanoseconds: 10_000_000) }
        checker.cancel(); state.slowDNS = false
        checker.start(model: model, target: "127.0.0.1", port: port, hostname: "localhost")
        try await finished(checker)
        guard checker.checks.filter({ $0.id == "dns" }).count == 1 else { throw Failure.check }
        state.slowDNS = true
        checker.start(model: model, target: "127.0.0.1", port: port, hostname: "localhost", timeout: 20_000_000)
        try await finished(checker)
        try await Task.sleep(nanoseconds: 100_000_000)
        guard checker.checks.last?.id == "deadline", checker.status.contains("超时") else { throw Failure.check }
        state.slowDNS = false; state.staleLookup = true
        checker.start(model: model, target: "127.0.0.1", port: port, hostname: "localhost")
        try await finished(checker)
        guard checker.stale, checker.checks.contains(where: { $0.id == "route" && $0.severity == .warning }) else { throw Failure.check }
        print("PASS: per-profile custom persistence and stale-save refusal, active edit lock, applied receipt, fenced read-only route lookup, one-click real loopback TCP/system DNS, cancellation, restart, deadline and stale session; no VPN or system-network mutations.")
    }
    private static func finished(_ model: TroubleshootingModel) async throws {
        for _ in 0..<600 { if !model.running { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw Failure.check
    }
    enum Failure: Error { case check, unexpectedSuccess }
}
