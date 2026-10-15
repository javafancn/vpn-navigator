import Foundation

/// A *candidate* PF firewall policy. Creating it does not change macOS PF.
/// Activation requires reviewing the host's PF anchor evaluation order,
/// preserving system PF state and proving cleanup on actual signed machines.
public struct FirewallRulePreview: Sendable {
    public enum Transport: String, Sendable {
        case udp, tcp
    }
    public enum Policy: Sendable {
        case fullVPN
        case chinaDirect([IPv4CIDR])
    }

    public let physicalInterface: String
    public let tunnelInterface: String
    public let endpointIPv4: String
    public let endpointPort: UInt16
    public let transport: Transport
    public let policy: Policy
    public let localNetworks: [IPv4CIDR]

    public init(physicalInterface: String, tunnelInterface: String,
                endpointIPv4: String, endpointPort: UInt16, transport: Transport,
                policy: Policy, localNetworks: [IPv4CIDR]) throws {
        // A broad direct exception would silently defeat the physical egress block.
        // Treat all inputs as untrusted, including caller-provided country routes.
        let countryRoutesAreBounded: Bool
        switch policy {
        case .fullVPN: countryRoutesAreBounded = true
        case .chinaDirect(let routes):
            countryRoutesAreBounded = !routes.isEmpty && routes.allSatisfy { $0.prefix >= 8 }
        }
        guard countryRoutesAreBounded,
              Self.validInterface(physicalInterface, prefix: "en"),
              Self.validInterface(tunnelInterface, prefix: "utun"),
              endpointPort > 0,
              IPv4CIDR.parseAddress(endpointIPv4) != nil,
              !localNetworks.isEmpty,
              localNetworks.allSatisfy({ $0.prefix >= 8 }) else {
            throw FirewallPreviewError.invalidInput
        }
        self.physicalInterface = physicalInterface
        self.tunnelInterface = tunnelInterface
        self.endpointIPv4 = endpointIPv4
        self.endpointPort = endpointPort
        self.transport = transport
        self.policy = policy
        self.localNetworks = localNetworks
    }

    public func renderedRules() -> String {
        let direct: [IPv4CIDR]
        switch policy {
        case .fullVPN: direct = localNetworks
        case .chinaDirect(let cn):
            direct = Array(Set(localNetworks + cn)).sorted()
        }
        let table = direct.map(\.description).joined(separator: ", ")
        // Quick pass exceptions must occur BEFORE the quick physical block.
        // This policy only targets the verified physical interface, never
        // globally alters PF or disables other parties' PF configuration.
        return """
        # VPN Navigator candidate PF anchor: REVIEW ONLY, NEVER LOADED AUTOMATICALLY
        table <vpnnav_direct4> const { \(table) }
        pass out quick on \(physicalInterface) inet proto \(transport.rawValue) from any to \(endpointIPv4) port \(endpointPort) keep state
        pass out quick on \(physicalInterface) inet from any to <vpnnav_direct4> keep state
        block drop out quick on \(physicalInterface) inet from any to any
        block drop out quick on \(physicalInterface) inet6 from any to any
        """
    }

    private static func validInterface(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.count > prefix.count,
              value.count <= prefix.count + 4 else { return false }
        return value.dropFirst(prefix.count).allSatisfy { $0.isASCII && $0.isNumber }
    }
}

public enum FirewallPreviewError: Error {
    case invalidInput
}
