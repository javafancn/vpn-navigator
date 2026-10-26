import Foundation

public struct RuleSet: Sendable {
    public let routes: [IPv4CIDR]
    public init(text: String) throws {
        // Also enforced on data received over XPC, not only HTTP downloads.
        guard text.utf8.count <= 2_000_000 else { throw RuleError.tooLarge }
        var result = Set<IPv4CIDR>()
        for row in text.components(separatedBy: .newlines) {
            let line = row.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard !line.contains(":") else { throw CIDRError.invalid(line) }
            let route = try IPv4CIDR(line)
            // Refuse default-route and private/special prefixes from a third-party GeoIP feed.
            guard route.prefix >= 8, !Self.isSpecial(route) else { throw CIDRError.invalid(line) }
            result.insert(route)
            guard result.count <= 30_000 else { throw RuleError.tooLarge }
        }
        guard !result.isEmpty else { throw RuleError.empty }
        routes = result.sorted()
    }
    /// Exclude destinations reserved for LAN, diagnostics, multicast, shared
    /// address space, or documentation, including *broader CIDRs that overlap*
    /// a reserved range (for example 192.0.0.0/8 overlaps 192.168.0.0/16).
    /// This feed must never replace connected or special-purpose routes.
    private static let reserved: [IPv4CIDR] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
        "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24",
        "192.168.0.0/16", "198.18.0.0/15",
        "198.51.100.0/24", "203.0.113.0/24",
        "224.0.0.0/4", "240.0.0.0/4"
    ].compactMap { try? IPv4CIDR($0) }

    private static func isSpecial(_ cidr: IPv4CIDR) -> Bool {
        reserved.contains { $0.overlaps(cidr) }
    }
    public func contains(ip: String) -> Bool {
        guard let address = IPv4CIDR.parseAddress(ip) else { return false }
        return routes.contains { $0.contains(address) }
    }
    public func diff(from old: RuleSet) -> (added: [IPv4CIDR], removed: [IPv4CIDR]) {
        let previous = Set(old.routes), next = Set(routes)
        return (next.subtracting(previous).sorted(), previous.subtracting(next).sorted())
    }
}
public enum RuleError: Error, LocalizedError {
    case empty, tooLarge, suspiciousChange
    public var errorDescription: String? {
        switch self { case .empty: return L10n.text("Rules file was empty")
        case .tooLarge: return L10n.text("Rules file exceeds the safe limit")
        case .suspiciousChange: return L10n.text("The IP feed changed unexpectedly; the previous validated version was preserved") }
    }
}

public enum ProfileCompiler {
    // The only exporter in the MVP: never run downloaded OpenVPN scripts as root.
    public static func render(original: String, mode: RoutingMode, rules: RuleSet?, custom: CustomRuleSet = .empty) throws -> String {
        let marker = "# VPNNAVIGATOR GENERATED ROUTES"
        guard !original.contains(marker) else { throw CompilerError.alreadyGenerated }
        let normalized = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .original { return original }
        guard !normalized.isEmpty else { throw CompilerError.emptyProfile }
        var lines = [normalized, "", marker]
        switch mode {
        case .original: break
        case .fullVPN:
            lines.append("redirect-gateway def1")
        case .chinaDirect:
            guard let rules else { throw CompilerError.missingRules }
            lines.append("redirect-gateway def1")
            _ = rules

        }
        let direct = try custom.directPrefixes(country: mode == .chinaDirect ? rules : nil, local: [], endpoint: nil)
        lines.append(contentsOf: direct.map { "route \(IPv4CIDR.parseAddressString($0.network)) \($0.netmask) net_gateway" })
        let rules6 = custom.active.filter { $0.cidr.contains(":") }
        if !rules6.isEmpty {
            lines.append("# IPv6 policy is installed by VPN Navigator after tunnel and physical gateway verification.")
            lines.append(contentsOf: rules6.map { "# IPv6 custom \($0.action.rawValue): \($0.cidr)" })
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
public enum CompilerError: Error { case alreadyGenerated, emptyProfile, missingRules }
extension IPv4CIDR {
    public static func parseAddressString(_ address: UInt32) -> String {
        "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }
}
