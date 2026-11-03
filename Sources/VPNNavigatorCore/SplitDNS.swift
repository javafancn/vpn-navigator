import Foundation

/// Match complete DNS labels; neither a substring nor a CNAME answer can
/// redirect an unlisted query to a physical resolver.
public struct ChinaDNSDomains: Sendable {
    private let names: Set<String>
    public static let empty = ChinaDNSDomains(names: [])
    private init(names: Set<String>) { self.names = names }
    public init(text: String) throws {
        guard text.utf8.count <= 4_000_000 else { throw RuleError.tooLarge }
        let rows = text.split(separator: "\n").map(String.init)
        guard !rows.isEmpty, rows.count <= 150_000, rows.allSatisfy(Self.valid) else { throw RuleError.tooLarge }
        names = Set(rows)
    }
    private static func valid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 253 && name == name.lowercased() &&
        name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }
    public func contains(_ name: String) -> Bool {
        var rest = name.lowercased()
        if rest.hasSuffix(".") { rest.removeLast() }
        guard Self.valid(rest) else { return false }
        while true {
            if names.contains(rest) { return true }
            guard let dot = rest.firstIndex(of: ".") else { return false }
            rest = String(rest[rest.index(after: dot)...])
        }
    }
}

public struct DNSQuestion: Equatable, Sendable {
    public let name: String
    public let type: UInt16
    public let end: Int
    public init?(_ packet: Data, response: Bool = false) {
        let b = [UInt8](packet)
        guard (17...65_535).contains(b.count), b[2] & 0x80 == (response ? 0x80 : 0),
              b[2] & 0x78 == 0, b[4] == 0, b[5] == 1 else { return nil }
        var p = 12, labels: [String] = []
        while p < b.count && b[p] != 0 {
            let length = Int(b[p]); p += 1
            guard (1...63).contains(length), p + length < b.count,
                  b[p..<p+length].allSatisfy({ (33...126).contains($0) && $0 != 46 }) else { return nil }
            labels.append(String(decoding: b[p..<p+length], as: UTF8.self).lowercased()); p += length
            guard labels.count <= 127 else { return nil }
        }
        guard p + 5 <= b.count, b[p] == 0, b[p+3] == 0, b[p+4] == 1 else { return nil }
        name = labels.isEmpty ? "." : labels.joined(separator: "."); type = UInt16(b[p+1]) << 8 | UInt16(b[p+2]); end = p + 5
        guard name.utf8.count <= 253 else { return nil }
    }
    public func accepts(_ response: Data, request: Data) -> Bool {
        guard response.count >= 12, response.prefix(2) == request.prefix(2),
              let other = DNSQuestion(response, response: true) else { return false }
        return name == other.name && type == other.type
    }
    public func failure(for request: Data) -> Data {
        var bytes = [UInt8](request.prefix(end))
        bytes[2] = 0x80 | (bytes[2] & 1); bytes[3] = 0x82
        for i in 6...11 { bytes[i] = 0 }
        return Data(bytes)
    }
    /// Policy NODATA, not NXDOMAIN: the name can still have usable A records.
    /// No AD bit or negative TTL is asserted for this locally generated answer.
    public func noData(for request: Data) -> Data {
        var bytes = [UInt8](request.prefix(end))
        bytes[2] = 0x80 | (bytes[2] & 1); bytes[3] = 0x80 | (bytes[3] & 0x10)
        for i in 6...11 { bytes[i] = 0 }
        return Data(bytes)
    }
}

public enum SplitDNSPolicy {
    private static let knownResolvers: Set<String> = ["223.5.5.5", "223.6.6.6", "119.29.29.29",
        "2400:3200::1", "2400:3200:baba::1", "2402:4e00::", "2402:4e00:1::"]
    /// DNS addresses need the same scope policy at selection and route planning.
    /// Only observed on-link networks may admit special-use addresses; an
    /// arbitrary DHCP/manual address never becomes a general bypass exception.
    public static func permitsPhysicalResolver(_ text: String, local4: [IPv4CIDR] = [], local6: [IPv6CIDR] = [],
        country4: RuleSet? = nil, country6: IPv6RuleSet? = nil) -> Bool {
        guard let ip = try? ManagedDNSPolicy.servers(provided: [text], has4: true, has6: true).first else { return false }
        if let address = IPv4CIDR.parseAddress(ip) {
            if local4.contains(where: { $0.contains(address) }) { return true }
            guard (try? CustomRuleSet.prefix(ip)) != nil else { return false }
            let privateAddress = address >> 24 == 10 || address >> 20 == 0xac1 || address >> 16 == 0xc0a8
            return knownResolvers.contains(ip) || privateAddress || country4?.contains(ip: ip) == true
        }
        if local6.contains(where: { $0.contains(ip) }) { return true }
        guard (try? CustomRuleSet.prefix6(ip)) != nil else { return false }
        let privateAddress = IPv6CIDR.parseAddress(ip).map { $0[0] & 0xfe == 0xfc } ?? false
        return knownResolvers.contains(ip) || privateAddress || country6?.contains(ip) == true
    }
    /// Only China Direct adds these explicit physical DNS exceptions.
    public static func domesticServers(path4: Bool, path6: Bool, protectedVPN: [String], preferred: [String] = [],
        local4: [IPv4CIDR] = [], local6: [IPv6CIDR] = [], country4: RuleSet? = nil, country6: IPv6RuleSet? = nil) -> [String] {
        let fallback = path4 ? ["223.5.5.5", "223.6.6.6", "119.29.29.29"]
            : path6 ? ["2400:3200::1", "2400:3200:baba::1", "2402:4e00::", "2402:4e00:1::"] : []
        let excluded = Set(protectedVPN.compactMap(IPAddress.canonical))
        var result: [String] = []
        for raw in preferred + fallback {
            // Reuse the unicast/family validation, including rejecting loopback
            // and scoped/link-local IPv6 resolvers which require another path.
            guard let ip = try? ManagedDNSPolicy.servers(provided: [raw], has4: path4, has6: path6).first,
                  !excluded.contains(ip), !result.contains(ip),
                  permitsPhysicalResolver(ip, local4: local4, local6: local6, country4: country4, country6: country6) else { continue }
            result.append(ip)
            if result.count == 2 { break }
        }
        return result
    }
}
