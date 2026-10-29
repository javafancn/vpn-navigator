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
}
