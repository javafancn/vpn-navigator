import Foundation
import VPNNavigatorCore

/// Read-only development utility: writes a *candidate* PF rules file.
/// Never calls pfctl, modifies /etc/pf.conf, or enables the firewall.
/// Numeric endpoint is a syntax-test fixture only.
@main
enum VPNNavigatorPFPreview {
    static func main() throws {
        if CommandLine.arguments.contains("--dual-stack") {
            let policy = try LeakGuardPolicy(physical: "en0", endpoint: "2606:4700::1111", port: 1194, transport: .udp,
                local: [IPv4CIDR("192.168.1.0/24")], country: [], physical4: "en0", physical6: "en0",
                local6: [IPv6CIDR("fd12::/64")], managedDirect6: [IPv6CIDR("240e::/20")], ipv6Tunnel: true)
            print(try policy.rules(tunnel: "utun4")); return
        }
        if CommandLine.arguments.contains("--strict") {
            let guardPolicy = try LeakGuardPolicy(physical: "en0", endpoint: "8.8.8.8", port: 1194,
                transport: .udp, local: [IPv4CIDR("192.168.1.0/24")], country: [IPv4CIDR("223.5.5.0/24")])
            print(try guardPolicy.rules(tunnel: nil))
            return
        }
        let policy = try FirewallRulePreview(
            physicalInterface: "en0",
            tunnelInterface: "utun4",
            endpointIPv4: "8.8.8.8",
            endpointPort: 1194,
            transport: .udp,
            policy: .chinaDirect([try IPv4CIDR("223.5.5.0/24")]),
            localNetworks: [try IPv4CIDR("192.168.1.0/24")])
        print(policy.renderedRules())
    }
}

