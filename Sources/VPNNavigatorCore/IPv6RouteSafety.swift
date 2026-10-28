import Foundation

/// macOS's IPv6 routing table is advisory only; this parser reports
/// potentially unsafe physical defaults conservatively.
public enum IPv6RouteSafety: Equatable, Sendable {
    case noDefaultRoute
    case linkLocalOnly
    case tunnelOnly
    case physicalBypass
    case unknown

    public static func evaluate(_ text: String, interfaces: String? = nil) -> Self {
        let lines = text.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Internet6:") }),
              let header = lines.first(where: { $0.contains("Destination") && $0.contains("Netif") }) else {
            return .unknown
        }
        let columns = header.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let flagIndex = columns.firstIndex(of: "Flags"), let interfaceIndex = columns.firstIndex(of: "Netif") else { return .unknown }
        var foundDefault = false
        var scopedOnly = true
        var tunnels = Set<String>()
        for row in lines {
            let tokens = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.first == "default" else { continue }
            foundDefault = true
            guard tokens.count > max(flagIndex, interfaceIndex), tokens.count > 1 else { return .unknown }
            let flags = tokens[flagIndex], interface = tokens[interfaceIndex]
            guard flags.contains("U"), flags.allSatisfy({ $0.isASCII && $0.isLetter }) else { return .unknown }
            if DNSRecoveryPolicy.validTunnel(interface) {
                tunnels.insert(interface)
                let gateway = tokens[1].split(separator: "%", omittingEmptySubsequences: false).map(String.init)
                let scopedGateway = gateway.count <= 2 && (gateway.count == 1 || gateway[1] == interface) &&
                    IPv6CIDR.parseAddress(gateway[0]).map(isLinkLocal) == true
                let linkGateway = tokens[1].hasPrefix("link#") && Int(tokens[1].dropFirst(5)) != nil
                scopedOnly = scopedOnly && flags.contains("I") && !flags.contains("R") && !flags.contains("B") && (scopedGateway || linkGateway)
            } else {
                guard interface.range(of: #"^(en|bridge|pdp_ip|awdl|llw)[0-9]+$"#, options: .regularExpression) != nil else { return .unknown }
                return .physicalBypass
            }
        }
        guard foundDefault else { return .noDefaultRoute }
        // RTF_IFSCOPE alone is insufficient: a bound application could still
        // use that route. Require a complete address snapshot with no usable
        // non-link-local IPv6 source on ANY interface before accepting it.
        if scopedOnly, let interfaces, onlyLocalSources(interfaces, required: tunnels) { return .linkLocalOnly }
        return .tunnelOnly
    }
    private static func isLinkLocal(_ address: [UInt8]) -> Bool {
        address.count == 16 && address[0] == 0xfe && address[1] & 0xc0 == 0x80
    }
    private static func onlyLocalSources(_ text: String, required: Set<String>) -> Bool {
        var current: String?, seen = Set<String>(), addresses = 0
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if !raw.hasPrefix(" ") && !raw.hasPrefix("\t") {
                guard line.contains("flags="), let name = line.split(separator: ":").first,
                      name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return false }
                current = String(name); seen.insert(String(name)); continue
            }
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.first == "inet6" else { continue }
            guard let current, fields.count >= 2 else { return false }
            let parts = fields[1].split(separator: "%", omittingEmptySubsequences: false).map(String.init)
            guard parts.count <= 2, (parts.count == 1 || parts[1] == current),
                  let address = IPv6CIDR.parseAddress(parts[0]) else { return false }
            addresses += 1
            let loopback = current == "lo0" && address.dropLast().allSatisfy({ $0 == 0 }) && address.last == 1
            guard loopback || isLinkLocal(address) else { return false }
        }
        return addresses > 0 && seen.contains("lo0") && required.isSubset(of: seen)
    }
}
