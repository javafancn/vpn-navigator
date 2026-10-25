#if DEBUG
import Foundation
import VPNNavigatorCore

enum DualStackRouteSelfTest {
    final class OS {
        var live4: [RouteTarget] = [], live6: [IPv6RouteTarget] = []
        var known4: [RouteTarget] = [], known6: [IPv6RouteTarget] = []
        var trace: [String] = []
        var fail6 = false
        func run(_ executable: String, _ args: [String]) throws -> String {
            let v6 = args.contains("inet6") || args.contains("-inet6")
            if executable == "/usr/sbin/netstat" { return v6 ? live6.map { $0.prefix.description + " fixture" }.joined(separator: "\n") : live4.map { $0.prefix.description + " fixture" }.joined(separator: "\n") }
            guard let cidr = args.first(where: { $0.contains("/") }) else { throw Failure.check }
            if v6 {
                guard let route = known6.first(where: { $0.prefix.description == cidr }) else { throw Failure.check }
                if args.contains("get") {
                    guard live6.contains(route) else { throw Failure.check }
                    let iface: String, gateway: String
                    switch route.destination { case .interface(let value): iface = value; gateway = "link#9"; case .viaGateway(let value): iface = "en0"; gateway = value }
                    return "destination: \(route.prefix.address)\nmask: \(route.prefix.netmask)\ninterface: \(iface)\ngateway: \(gateway)"
                }
                if args.contains("add") { if fail6 { throw Failure.check }; live6.append(route) }
                else { live6.removeAll { $0 == route } }
            } else {
                guard let route = known4.first(where: { $0.prefix.description == cidr }) else { throw Failure.check }
                if args.contains("get") {
                    guard live4.contains(route) else { throw Failure.check }
                    let iface: String, gateway: String
                    switch route.destination { case .interface(let value): iface = value; gateway = "link#9"; case .viaGateway(let value): iface = "en0"; gateway = value }
                    return "destination: \(IPv4CIDR.parseAddressString(route.prefix.network))\nmask: \(route.prefix.netmask)\ninterface: \(iface)\ngateway: \(gateway)"
                }
                if args.contains("add") { live4.append(route) } else { live4.removeAll { $0 == route } }
            }
            trace.append((args.contains("add") ? "add:" : "delete:") + cidr)
            return ""
        }
    }
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dual-routes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local4 = [try IPv4CIDR("192.168.1.0/24")], local6 = [try IPv6CIDR("fd12::/64")]
        let p4 = try PhysicalIPPath(gateway: "192.168.1.1", interface: "en0"), p6 = try PhysicalIPPath(gateway: "fe80::1%en0", interface: "en0")
        let custom = try CustomRuleSet([.init(cidr: "240e:1::/32", action: .vpn), .init(cidr: "2606:4700::1111", action: .direct), .init(cidr: "9.9.9.9", action: .direct)])
        func plan(_ mode: RoutingMode) throws -> DualStackRoutePlan {
            try .build(endpoint: "2606:4700::2222", tunnel: "utun4", has4: true, has6: true, path4: p4, path6: p6,
                local4: local4, local6: local6, mode: mode, country4: mode == .chinaDirect ? RuleSet(text: "11.0.0.0/8") : nil,
                country6: mode == .chinaDirect ? IPv6RuleSet(text: "240e::/20") : nil, custom: custom)
        }
        let full = try plan(.fullVPN), split = try plan(.chinaDirect)
        let os = OS(); os.known4 = full.ipv4 + split.ipv4; os.known6 = full.ipv6 + split.ipv6
        let file = root.appendingPathComponent("routes")
        let executor = RouteExecutor(journal: file, run: os.run)
        try executor.apply(full.ipv4); try executor.applyIPv6(full.ipv6); os.trace = []
        try DualStackTransitionExecutor.apply(from: full, to: split, executor: executor,
            updateProtection: { _ in os.trace.append("PF") }, verify: { os.trace.append("verified") })
        guard os.trace.suffix(2).elementsEqual(["verified", "PF"]),
              Set(executor.installed6) == Set(split.ipv6), Set(executor.installed) == Set(split.ipv4),
              !executor.installed6.contains(where: { split.direct6.contains($0) && $0.prefix.contains("240e:1::1") }) else { throw Failure.check }
        os.trace = []
        try DualStackTransitionExecutor.apply(from: split, to: full, executor: executor,
            updateProtection: { tightens in guard tightens else { throw Failure.check }; os.trace.append("PF") }, verify: { os.trace.append("verified") })
        guard os.trace.first == "PF", Set(executor.installed6) == Set(full.ipv6) else { throw Failure.check }
        let replay = RouteLedgerReplay(data: try Data(contentsOf: file))
        guard replay.permitsAutomaticRecovery, Set(replay.installed6) == Set(full.ipv6), Set(replay.installed) == Set(full.ipv4) else { throw Failure.check }
        executor.rollback()
        guard executor.installed.isEmpty, executor.installed6.isEmpty, os.live4.isEmpty, os.live6.isEmpty,
              !FileManager.default.fileExists(atPath: file.path) else { throw Failure.check }
        let failureOS = OS(); failureOS.known4 = full.ipv4; failureOS.known6 = full.ipv6; failureOS.fail6 = true
        let uncertain = root.appendingPathComponent("uncertain")
        let blocked = RouteExecutor(journal: uncertain, run: failureOS.run)
        try blocked.apply(full.ipv4)
        do { try blocked.applyIPv6(full.ipv6); throw Failure.unexpected } catch Failure.check { }
        blocked.rollback()
        guard blocked.installed == full.ipv4, !RouteLedgerReplay(data: try Data(contentsOf: uncertain)).permitsAutomaticRecovery else { throw Failure.check }
        let restarted = RouteExecutor(journal: uncertain, run: failureOS.run)
        guard restarted.installed == full.ipv4, !failureOS.trace.contains(where: { $0.hasPrefix("delete:") }) else { throw Failure.check }
        print("PASS: dual-stack IPv6 transport, both-family journal ownership and recovery, live full/split round trip, custom VPN subtraction, PF ordering and ambiguous IPv6 write blocks all cleanup; injected OS only.")
    }
    enum Failure: Error { case check, unexpected }
}
#endif
