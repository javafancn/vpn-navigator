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
    private func read(family: Int32, network: [UInt8], prefix: Int) throws -> String {
        var output = [CChar](repeating: 0, count: 1024)
        let result = network.withUnsafeBufferPointer { bytes in
            vpn_routes_inspect(descriptor, family, bytes.baseAddress, UInt8(prefix), &output, output.count)
        }
        guard result == 0 else { throw RouteExecutionError.kernelRouteFailed(Int(result)) }
        return String(cString: output)
    }
}
