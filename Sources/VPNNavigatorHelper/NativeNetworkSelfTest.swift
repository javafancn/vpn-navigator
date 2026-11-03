#if DEBUG
import Foundation
import VPNNavigatorCore

enum NativeNetworkSelfTest {
    static func run() throws {
        let reader = try KernelRouteReader(), snapshot = try NativeNetworkSnapshot()
        let table4 = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet"])
        let table6 = try RouteExecutor.command("/usr/sbin/netstat", ["-rn", "-f", "inet6"])
        for interface in snapshot.physicalInterfaces {
            let actual4 = snapshot.local4(on: interface), expected4 = LocalIPv4Networks.parse(netstat: table4, physicalInterface: interface)
            let actual6 = snapshot.local6(on: interface), expected6 = LocalIPv6Networks.parse(netstat: table6, physicalInterface: interface)
            guard actual4 == expected4, actual6 == expected6 else {
                let extra = Set(actual4).subtracting(expected4).map { "class\($0.network >> 24)/\($0.prefix)" }
                let missing = Set(expected4).subtracting(actual4).map { "class\($0.network >> 24)/\($0.prefix)" }
                throw Failure.local("\(interface): v4 \(actual4.count)/\(expected4.count), v6 \(actual6.count)/\(expected6.count); extra \(extra); missing \(missing)")
            }
        }
        func value(_ key: String, in text: String) -> String {
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(key + ":") }.map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) } ?? ""
        }
        for ip in ["127.0.0.1", "8.8.8.8", "223.5.5.5"] {
            let expected = try RouteExecutor.command("/sbin/route", ["-n", "get", ip])
            let actual = try reader.lookup(ip)
            guard actual.interface == value("interface", in: expected), actual.gateway == value("gateway", in: expected) else {
                throw Failure.host("interfaces \(actual.interface)/\(value("interface", in: expected)); gateway equal \(actual.gateway == value("gateway", in: expected))")
            }
        }
        for v6 in [false, true] {
            let expected = try? RouteExecutor.command("/sbin/route", ["-n", "get"] + (v6 ? ["-inet6"] : []) + ["-net", v6 ? "::/0" : "0.0.0.0/0"])
            let actual = try reader.defaultPath(ipv6: v6)
            guard actual.interface == value("interface", in: expected ?? "") else { throw Failure.defaultRoute(v6) }
        }
        let interfaces = try RouteExecutor.command("/sbin/ifconfig", ["-a"])
        let original = IPv6RouteSafety.evaluate(table6, interfaces: interfaces)
        let native = IPv6RouteSafety.evaluate(try KernelRouteReader.ipv6Defaults(), interfaces: snapshot.ipv6InterfaceText)
        guard original == native else { throw Failure.ipv6 }
        print("PASS: native physical networks, host/default route lookups and complete scoped IPv6 fallback classification match the system tools; all reads, no route mutations.")
    }
    enum Failure: Error { case local(String), host(String), defaultRoute(Bool), ipv6 }
}
#endif
