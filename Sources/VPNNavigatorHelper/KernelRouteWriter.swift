import Foundation
import Darwin
import CVPNRoutes
import VPNNavigatorCore

/// Reuse one close-on-exec socket instead of spawning thousands of route tools.
/// The executor still fsyncs begin/commit records around EACH kernel mutation.
final class KernelRouteWriter {
    private let descriptor: Int32
    init() throws {
        descriptor = vpn_routes_open()
        guard descriptor >= 0 else { throw RouteExecutionError.commandLaunchFailed(Int(errno)) }
    }
    deinit { close(descriptor) }
    func apply(_ route: RouteTarget, adding: Bool) throws {
        guard case .viaGateway(let value) = route.destination,
              let gateway = IPv4CIDR.parseAddress(value) else { throw RouteExecutionError.disallowedExecutable }
        let result = vpn_routes_gateway4(descriptor, route.prefix.network, UInt8(route.prefix.prefix), gateway, adding ? 1 : 0)
        guard result == 0 else { throw RouteExecutionError.kernelRouteFailed(Int(result)) }
    }
    func apply(_ route: IPv6RouteTarget, adding: Bool) throws {
        guard case .viaGateway(let value) = route.destination else { throw RouteExecutionError.disallowedExecutable }
        let parts = value.split(separator: "%", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), let gateway = IPv6CIDR.parseAddress(parts[0]) else {
            throw RouteExecutionError.disallowedExecutable
        }
        let scope: UInt32
        if parts.count == 2 {
            scope = if_nametoindex(parts[1])
            guard scope > 0 else { throw RouteExecutionError.kernelRouteFailed(Int(ENXIO)) }
        } else { scope = 0 }
        let result = route.prefix.network.withUnsafeBufferPointer { network in
            gateway.withUnsafeBufferPointer { gateway in
                vpn_routes_gateway6(descriptor, network.baseAddress, UInt8(route.prefix.prefix), gateway.baseAddress, scope, adding ? 1 : 0)
            }
        }
        guard result == 0 else { throw RouteExecutionError.kernelRouteFailed(Int(result)) }
    }
}
