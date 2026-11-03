import Foundation
import Darwin
import CVPNRoutes
import VPNNavigatorCore

/// Exact, fresh ownership reads without launching a process per prefix.
/// The reply decoder feeds the same conservative ownership checks as route(8).
final class KernelRouteReader {
    private let descriptor: Int32
    init() throws {
        descriptor = vpn_routes_reader_open()
        guard descriptor >= 0 else { throw RouteExecutionError.kernelRouteFailed(Int(errno)) }
    }
    deinit { close(descriptor) }
    func observe(_ route: RouteTarget) throws -> ObservedIPv4Route {
        let value = route.prefix.network
        let bytes = [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
        return ObservedIPv4Route(commandOutput: try read(family: AF_INET, network: bytes, prefix: route.prefix.prefix))
    }
    func observe(_ route: IPv6RouteTarget) throws -> ObservedIPv6Route {
        ObservedIPv6Route(commandOutput: try read(family: AF_INET6, network: route.prefix.network, prefix: route.prefix.prefix))
    }
    func lookup(_ ip: String) throws -> (interface: String, gateway: String) {
        let v6 = IPAddress.isIPv6(ip)
        let bytes: [UInt8]
        if v6, let address = IPv6CIDR.parseAddress(ip) { bytes = address }
        else if let address = IPv4CIDR.parseAddress(ip) {
            bytes = [UInt8(address >> 24), UInt8((address >> 16) & 255), UInt8((address >> 8) & 255), UInt8(address & 255)]
        } else { throw TunnelError.routeVerificationFailed }
        return Self.path(try read(family: v6 ? AF_INET6 : AF_INET, network: bytes, prefix: nil))
    }
    func defaultPath(ipv6: Bool) throws -> (interface: String, gateway: String) {
        Self.path(try read(family: ipv6 ? AF_INET6 : AF_INET, network: [UInt8](repeating: 0, count: ipv6 ? 16 : 4), prefix: 0))
    }
    static func ipv6Defaults() throws -> String {
        var bytes = [CChar](repeating: 0, count: 32_768)
        let result = vpn_routes_ipv6_defaults(&bytes, bytes.count)
        guard result == 0 else { throw RouteExecutionError.kernelRouteFailed(Int(result)) }
        return String(cString: bytes)
    }
    private static func path(_ output: String) -> (interface: String, gateway: String) {
        func value(_ key: String) -> String {
            output.components(separatedBy: .newlines).first { $0.hasPrefix(key + ": ") }.map { String($0.dropFirst(key.count + 2)) } ?? ""
        }
        return (value("interface"), value("gateway"))
    }
    private func read(family: Int32, network: [UInt8], prefix: Int?) throws -> String {
        var output = [CChar](repeating: 0, count: 1024)
        let result = network.withUnsafeBufferPointer { bytes in
            if let prefix { return vpn_routes_inspect(descriptor, family, bytes.baseAddress, UInt8(prefix), &output, output.count) }
            return vpn_routes_lookup(descriptor, family, bytes.baseAddress, &output, output.count)
        }
        guard result == 0 else { throw RouteExecutionError.kernelRouteFailed(Int(result)) }
        return String(cString: output)
    }
}
