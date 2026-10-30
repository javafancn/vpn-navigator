import Foundation

/// Match complete DNS labels; neither a substring nor a CNAME answer can
/// redirect an unlisted query to a physical resolver.
public struct ChinaDNSDomains: Sendable {
    private let names: Set<String>
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
}

public enum SplitDNSPolicy {
    /// Only China Direct adds these explicit physical DNS exceptions.
    public static func domesticServers(path4: Bool, path6: Bool, protectedVPN: [String]) -> [String] {
        let candidates = path4 ? ["223.5.5.5", "223.6.6.6", "119.29.29.29"]
            : path6 ? ["2400:3200::1", "2400:3200:baba::1", "2402:4e00::", "2402:4e00:1::"] : []
        let excluded = Set(protectedVPN.compactMap(IPAddress.canonical))
        return Array(candidates.filter { !excluded.contains($0) }.prefix(2))
    }
}
