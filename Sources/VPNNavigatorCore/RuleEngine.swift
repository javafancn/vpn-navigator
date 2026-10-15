import Foundation

public struct RuleSet: Sendable {
    public let routes: [IPv4CIDR]
    public init(text: String) throws {
        var result = Set<IPv4CIDR>()
        for row in text.components(separatedBy: .newlines) {
            let line = row.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard !line.contains(":") else { throw CIDRError.invalid(line) }
            let route = try IPv4CIDR(line)
            // Refuse default-route and private/special prefixes from a third-party GeoIP feed.
            guard route.prefix >= 8, !Self.isSpecial(route) else { throw CIDRError.invalid(line) }
            result.insert(route)
        }
        guard !result.isEmpty else { throw RuleError.empty }
        routes = result.sorted()
    }
    private static func isSpecial(_ cidr: IPv4CIDR) -> Bool {
        let first = cidr.network >> 24
        if first == 0 || first == 10 || first == 127 || first >= 224 { return true }
        let second = (cidr.network >> 16) & 255
        if first == 169 && second == 254 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 100 && (64...127).contains(second) { return true }
        return false
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
        switch self { case .empty: return "Rules file was empty"
        case .tooLarge: return "Rules file exceeds the safe limit"
        case .suspiciousChange: return "The IP feed changed unexpectedly; the previous validated version was preserved" }
    }
}

public enum ProfileCompiler {
    // The only exporter in the MVP: never run downloaded OpenVPN scripts as root.
    public static func render(original: String, mode: RoutingMode, rules: RuleSet?) throws -> String {
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
            lines.append(contentsOf: rules.routes.map { "route \(IPv4CIDR.parseAddressString($0.network)) \($0.netmask) net_gateway" })
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
