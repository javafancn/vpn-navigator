import Foundation

public struct NetworkHealthSummary: Sendable {
    public let ipv6Safety: IPv6RouteSafety
    public let ipv4DefaultInterface: String?
    public let resolverCount: Int
    public let nameserverCount: Int

    public init(ipv6Table: String, defaultIPv4Route: String, dnsSummary: String) {
        ipv6Safety = IPv6RouteSafety.evaluate(ipv6Table)
        ipv4DefaultInterface = defaultIPv4Route
            .components(separatedBy: .newlines)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("interface:") })?
            .split(separator: ":", maxSplits: 1).last
            .map { $0.trimmingCharacters(in: .whitespaces) }
        resolverCount = dnsSummary.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("resolver #") }.count
        nameserverCount = dnsSummary.components(separatedBy: .newlines)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("nameserver[") }.count
    }
}
