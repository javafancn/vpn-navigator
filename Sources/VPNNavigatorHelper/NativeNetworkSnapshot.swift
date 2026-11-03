import Foundation
import Darwin
import CVPNRoutes
import VPNNavigatorCore

/// Small interface/address snapshot, independent of the country routing table.
/// Binary route snapshots preserve on-link LANs; getifaddrs supplies IPv6 sources.
/// No netstat/ifconfig subprocesses or country-route text parsing is needed.
struct NativeNetworkSnapshot {
    private var ipv4: [String: Set<IPv4CIDR>] = [:]
    private var ipv6: [String: Set<IPv6CIDR>] = [:]
    private var sources6: [String: [String]] = [:]
    private var names = Set<String>()
    init() throws {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { throw TunnelError.noPhysicalGateway }
        defer { freeifaddrs(first) }
        var current = first
        while let node = current {
            defer { current = node.pointee.ifa_next }
            let item = node.pointee, name = String(cString: node.pointee.ifa_name)
            names.insert(name)
            guard let address = item.ifa_addr else { continue }
            if address.pointee.sa_family == UInt8(AF_INET6) {
                let bytes = Self.addressBytes(address, ipv6: true)
                sources6[name, default: []].append(IPv6CIDR.addressString(bytes))
            }
        }
        // Interface addresses alone omit system-created on-link routes (for
        // example IPv4 link-local reachability). Preserve the exact old LAN
        // semantics using the binary route table, filtered before formatting.
        let table4 = try Self.localTable(family: AF_INET), table6 = try Self.localTable(family: AF_INET6)
        for name in names where LeakGuardPolicy.validPhysical(name) {
            ipv4[name] = Set(LocalIPv4Networks.parse(netstat: table4, physicalInterface: name))
            ipv6[name] = Set(LocalIPv6Networks.parse(netstat: table6, physicalInterface: name))
        }
    }
    private static func localTable(family: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: 131_072)
        let result = vpn_routes_local_networks(family, &bytes, bytes.count)
        guard result == 0 else { throw RouteExecutionError.kernelRouteFailed(Int(result)) }
        return String(cString: bytes)
    }
    func local4(on interface: String?) -> [IPv4CIDR] { interface.map { (ipv4[$0] ?? []).sorted() } ?? [] }
    var physicalInterfaces: [String] { names.filter(LeakGuardPolicy.validPhysical).sorted() }
    func local6(on interface: String?) -> [IPv6CIDR] { interface.map { (ipv6[$0] ?? []).sorted() } ?? [] }
    var ipv6InterfaceText: String {
        names.sorted().map { name in
            "\(name): flags=0\n" + (sources6[name] ?? []).map { "\tinet6 \($0)\n" }.joined()
        }.joined()
    }
    private static func addressBytes(_ value: UnsafePointer<sockaddr>, ipv6: Bool) -> [UInt8] {
        if ipv6 {
            return value.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                var address = pointer.pointee.sin6_addr
                return withUnsafeBytes(of: &address) { Array($0) }
            }
        }
        return value.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
            var address = pointer.pointee.sin_addr
            return withUnsafeBytes(of: &address) { Array($0) }
        }
    }
}
