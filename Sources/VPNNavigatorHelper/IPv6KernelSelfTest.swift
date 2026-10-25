#if VPNNAV_LOCAL_TEST
import Foundation
import VPNNavigatorCore

/// Disposable local-channel CI only. Uses two fixed documentation prefixes,
/// never a default route. Shares the normal journal so interrupted tests block
/// recovery/update until the ordinary ownership checks have completed.
enum IPv6KernelSelfTest {
    static func run(tunnel: String) throws {
        let journal = URL(fileURLWithPath: "/var/run/vpn-navigator/routes.journal")
        guard DNSRecoveryPolicy.validTunnel(tunnel), !FileManager.default.fileExists(atPath: journal.path),
              try RouteExecutor.command("/sbin/ifconfig", [tunnel]).contains("fd42:766e:6176:1:") else { throw DualStackError.missingTunnel }
        let routes = try [IPv6RouteTarget(IPv6CIDR("2001:db8:fffe:1::/64"), .interface(tunnel)),
                          IPv6RouteTarget(IPv6CIDR("2001:db8:fffe:2::1/128"), .interface(tunnel))]
        let executor = RouteExecutor(journal: journal)
        defer { executor.rollback() }
        try executor.applyIPv6(routes)
        for route in routes {
            let raw = try RouteExecutor.command("/sbin/route", ["-n", "get", "-inet6", "-net", route.prefix.description])
            guard ObservedIPv6Route(commandOutput: raw).isExactly(route) else {
                fputs("IPv6 kernel fixture observation: \(raw)\n", stderr)
                throw RouteExecutionError.routeOwnershipLost(route.prefix.description)
            }
        }
        executor.rollback()
        guard executor.installed6.isEmpty, !FileManager.default.fileExists(atPath: journal.path) else { throw RouteExecutionError.journalFailure }
        print("PASS: actual macOS IPv6 prefix/host route installation, exact ownership observation and journaled rollback on an existing fixture utun; default routes unchanged.")
    }
}
#endif
