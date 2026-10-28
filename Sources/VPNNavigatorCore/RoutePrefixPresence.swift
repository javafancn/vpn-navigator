import Foundation

/// Exact-prefix presence on any interface, including interface-scoped routes.
/// A failed or unfamiliar table never proves absence for recovery purposes.
public enum RoutePrefixPresence: Equatable, Sendable {
    case present, absent, unknown

    public static func ipv4(_ target: IPv4CIDR, table: String) -> Self {
        evaluate(table, family: "Internet:") { destination, flags in
            let parts = destination.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { return nil }
            var octets = parts[0].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (1...4).contains(octets.count) else { return nil }
            let bits: Int
            if parts.count == 2 {
                guard let value = Int(parts[1]), (0...32).contains(value) else { return nil }
                bits = value
            } else {
                guard flags.contains("H") || octets.count < 4 else { return nil }
                bits = flags.contains("H") ? 32 : octets.count * 8
            }
            while octets.count < 4 { octets.append("0") }
            guard let value = try? IPv4CIDR(octets.joined(separator: ".") + "/\(bits)") else { return nil }
            return value == target
        }
    }

    public static func ipv6(_ target: IPv6CIDR, table: String) -> Self {
        evaluate(table, family: "Internet6:") { destination, flags in
            let parts = destination.split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { return nil }
            let address = String(parts[0].split(separator: "%", omittingEmptySubsequences: false)[0])
            let bits: Int
            if parts.count == 2 {
                guard let value = Int(parts[1]), (0...128).contains(value) else { return nil }
                bits = value
            } else {
                guard flags.contains("H") else { return nil }
                bits = 128
            }
            guard let value = try? IPv6CIDR(address + "/\(bits)") else { return nil }
            return value == target
        }
    }

    private static func evaluate(_ table: String, family: String, matches: (String, String) -> Bool?) -> Self {
        guard table.utf8.count <= 8_000_000 else { return .unknown }
        var familySeen = false, flagIndex: Int?, interfaceIndex: Int?, malformed = false
        for row in table.components(separatedBy: .newlines) {
            let line = row.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line == "Routing tables" { continue }
            if line == family { familySeen = true; continue }
            guard familySeen else { continue }
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if fields.first == "Destination" {
                flagIndex = fields.firstIndex(of: "Flags")
                interfaceIndex = fields.firstIndex(of: "Netif")
                continue
            }
            guard let flagIndex, let interfaceIndex, fields.count > max(flagIndex, interfaceIndex) else { malformed = true; continue }
            guard fields[flagIndex].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { malformed = true; continue }
            if fields[0] == "default" { continue }
            guard let found = matches(fields[0], fields[flagIndex]) else { malformed = true; continue }
            if found { return .present }
        }
        return familySeen && flagIndex != nil && interfaceIndex != nil && !malformed ? .absent : .unknown
    }
}
