import Foundation

/// Parses the directly connected IPv4 networks on a macOS physical interface.
/// Never claims that a gateway route is an on-link LAN prefix.
public enum LocalIPv4Networks {
    public static func parse(netstat: String, physicalInterface: String) -> [IPv4CIDR] {
        guard !physicalInterface.isEmpty,
              netstat.components(separatedBy: .newlines).contains(where: {
                  $0.contains("Destination") && $0.contains("Gateway")
              }) else { return [] }
        var routes = Set<IPv4CIDR>()
        for row in netstat.components(separatedBy: .newlines) {
            let fields = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count >= 4, fields[3] == physicalInterface,
                  fields[1].hasPrefix("link#"), fields[0] != "default",
                  fields[0].contains("/") else { continue }
            let parts = fields[0].split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
                continue
            }
            var octets = String(parts[0]).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (1...4).contains(octets.count) else { continue }
            while octets.count < 4 { octets.append("0") }
            if let cidr = try? IPv4CIDR(octets.joined(separator: ".") + "/\(prefix)") {
                routes.insert(cidr)
            }
        }
        return routes.sorted()
    }
}
