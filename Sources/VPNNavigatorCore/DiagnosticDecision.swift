import Foundation

public enum ExpectedPath: String, Sendable { case vpn = "VPN", direct = "Direct", unchanged = "Original configuration" }
public struct DiagnosticDecision: Sendable {
    public let address: String
    public let expected: ExpectedPath
    public let reason: String
}
public enum IPDiagnostics {
    public static func decide(ip: String, mode: RoutingMode, rules: RuleSet?) -> DiagnosticDecision? {
        guard IPv4CIDR.parseAddress(ip) != nil else { return nil }
        switch mode {
        case .original:
            return .init(address: ip, expected: .unchanged, reason: "The imported profile controls this route.")
        case .fullVPN:
            return .init(address: ip, expected: .vpn, reason: "All IPv4 addresses use the VPN default route (unless a more specific system route exists).")
        case .chinaDirect:
            guard let rules else { return nil }
            if rules.contains(ip: ip) {
                return .init(address: ip, expected: .direct, reason: "The address matches a Mainland China IPv4 CIDR.")
            }
            return .init(address: ip, expected: .vpn, reason: "No Mainland China CIDR matched.")
        }
    }
}
