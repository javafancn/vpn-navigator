import Foundation
import VPNNavigatorCore

/// Read-only development utility: writes a *candidate* PF rules file.
/// Never calls pfctl, modifies /etc/pf.conf, or enables the firewall.
/// Numeric endpoint is a syntax-test fixture only.
@main
enum VPNNavigatorPFPreview {
    static func main() throws {
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
