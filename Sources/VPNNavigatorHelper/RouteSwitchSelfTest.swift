#if DEBUG
import Foundation
import VPNNavigatorCore

enum RouteSwitchSelfTest {
    final class Fixture {
        var live: [RouteTarget] = []
        var trace: [String] = []
        var known: [RouteTarget] = []
        var failAdd = false
        var cancelled = false
        func run(_ executable: String, _ args: [String]) throws -> String {
            if executable == "/usr/sbin/netstat" { return live.map { $0.prefix.description + " fixture" }.joined(separator: "\n") }
            guard let text = args.first(where: { $0.contains("/") }),
                  let route = known.first(where: { $0.prefix.description == text }) else { throw Failure.check }
            if args.contains("get") {
                guard live.contains(route) else { throw Failure.check }
                let gateway: String, interface: String
                switch route.destination {
                case .viaGateway(let value): gateway = value; interface = "en0"
                case .interface(let value): gateway = "link#1"; interface = value
                }
                return "destination: \(IPv4CIDR.parseAddressString(route.prefix.network))\nmask: \(route.prefix.netmask)\ngateway: \(gateway)\ninterface: \(interface)"
            }
            if args.contains("add") {
                if failAdd { throw Failure.check }
                live.append(route); trace.append("add:" + text)
            } else if args.contains("delete") { live.removeAll { $0 == route }; trace.append("delete:" + text) }
            else { throw Failure.check }
            return ""
        }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = [try IPv4CIDR("192.168.1.0/24")]
        let full = try RoutePlanner.build(serverIPv4: "203.0.113.7", physicalGateway: "192.168.1.1",
            vpnInterface: "utun4", localPrefixes: local, china: nil)
        let text = (0..<100).map { "11.0.\($0).0/24" }.joined(separator: "\n")
        let split = try ManagedRouteTransition(current: full, target: .chinaDirect, ruleText: text, local: local)
        let global = try ManagedRouteTransition(current: split.plan, target: .fullVPN, ruleText: "", local: local)
        let os = Fixture(); os.known = full.installOrder + split.added
        let executor = RouteExecutor(journal: root.appendingPathComponent("routes"), shouldCancel: { os.cancelled }, run: os.run)
        try executor.apply(full.installOrder); os.trace = []
        try RouteTransitionExecutor.apply(split, executor: executor,
            updateProtection: { os.trace.append("relax-protection") }, verify: { os.trace.append("verify-split") })
        guard os.trace.first?.hasPrefix("add:") == true, os.trace.suffix(2).elementsEqual(["verify-split", "relax-protection"]),
              Set(executor.installed) == Set(split.plan.installOrder) else { throw Failure.check }
        os.trace = []
        try RouteTransitionExecutor.apply(global, executor: executor,
            updateProtection: { os.trace.append("tighten-protection") }, verify: { os.trace.append("verify-global") })
        guard os.trace.first == "tighten-protection", os.trace.last == "verify-global",
              os.trace.filter({ $0.hasPrefix("delete:") }).count == 100,
              Set(executor.installed) == Set(full.installOrder) else { throw Failure.check }
        // A failed add must not release endpoint/defaults while the child lives.
        os.trace = []; os.failAdd = true
        do {
            try RouteTransitionExecutor.apply(split, executor: executor,
                updateProtection: { throw Failure.check }, verify: { throw Failure.check })
            throw Failure.unexpectedSuccess
        } catch Failure.check { }
        guard !os.trace.contains(where: { $0.hasPrefix("delete:") }),
              Set(executor.installed) == Set(full.installOrder),
              !RouteLedgerReplay(data: try Data(contentsOf: root.appendingPathComponent("routes"))).permitsAutomaticRecovery else { throw Failure.check }
        // The ambiguous write is preserved even after a later cleanup request.
        executor.rollback()
        guard Set(executor.installed) == Set(full.installOrder) else { throw Failure.check }
        let cancelOS = Fixture(); cancelOS.known = os.known
        let cancelled = RouteExecutor(journal: root.appendingPathComponent("cancelled"), shouldCancel: { cancelOS.cancelled }, run: cancelOS.run)
        try cancelled.apply(full.installOrder); cancelOS.cancelled = true; cancelOS.trace = []
        do {
            try RouteTransitionExecutor.apply(split, executor: cancelled, updateProtection: {}, verify: {})
            throw Failure.unexpectedSuccess
        } catch is CancellationError { }
        guard cancelled.installed == full.installOrder, cancelOS.trace.isEmpty else { throw Failure.check }
        print("PASS: live route transition add/remove order, PF tightening/relaxing, retained endpoint/defaults, cancellation and ambiguous journal; injected OS commands only.")
    }
    enum Failure: Error { case check, unexpectedSuccess }
}
#endif
