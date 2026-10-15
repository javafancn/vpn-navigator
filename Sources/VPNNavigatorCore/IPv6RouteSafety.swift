import Foundation

/// macOS's IPv6 routing table is advisory only; this parser reports
/// potentially unsafe physical defaults conservatively.
public enum IPv6RouteSafety: Equatable, Sendable {
    case noDefaultRoute
    case tunnelOnly
    case physicalBypass
    case unknown

    public static func evaluate(_ text: String) -> Self {
        let lines = text.components(separatedBy: .newlines)
        guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Internet6:") }),
              lines.contains(where: { $0.contains("Destination") && $0.contains("Netif") }) else {
            return .unknown
        }
        var foundDefault = false
        var foundTunnel = false
        for row in lines {
            let tokens = row.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.first == "default" else { continue }
            foundDefault = true
            let interfaces = tokens.filter {
                $0.range(of: #"^(en|utun|bridge|pdp_ip|awdl|llw)[0-9]+$"#,
                         options: .regularExpression) != nil
            }
            guard let interface = interfaces.last else { return .unknown }
            if interface.hasPrefix("utun") {
                foundTunnel = true
            } else {
                return .physicalBypass
            }
        }
        return foundDefault ? (foundTunnel ? .tunnelOnly : .unknown) : .noDefaultRoute
    }
}
