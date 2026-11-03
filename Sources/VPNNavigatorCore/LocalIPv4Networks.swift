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
                  fields[1].hasPrefix("link#"), fields[0] != "default", !fields[2].contains("H") else { continue }
            let parts = fields[0].split(separator: "/", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count) else { continue }
            var octets = String(parts[0]).split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard (1...4).contains(octets.count) else { continue }
            let prefix: Int
            if parts.count == 2 {
                guard let value = Int(parts[1]), (0...32).contains(value) else { continue }
                prefix = value
            } else { prefix = octets.count * 8 }
            while octets.count < 4 { octets.append("0") }
            if let cidr = try? IPv4CIDR(octets.joined(separator: ".") + "/\(prefix)") {
                // Darwin also installs link# routes for multicast/broadcast.
                // Those are not LANs and must never enter a PF allow table.
                let first = cidr.network >> 24
                guard first != 0, first != 127, first < 224 else { continue }
                routes.insert(cidr)
            }
        }
        return routes.sorted()
    }
}
