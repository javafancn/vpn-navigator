import Foundation

/// Parses RIR's delegated statistics exchange format. APNIC registry country
/// reflects resource registration, NOT necessarily actual geographic location,
/// BGP visibility, or where packets physically flow.
public enum APNICIPv6Delegations {
    public static func parse(_ data: String) throws -> IPv6RuleSet {
        guard data.utf8.count < 8_000_000 else { throw APNICIPv6Error.oversized }
        var lines: [String] = []
        for raw in data.components(separatedBy: .newlines) {
            if raw.isEmpty || raw.hasPrefix("#") { continue }
            let columns = raw.split(separator: "|", omittingEmptySubsequences: false)
            guard columns.count >= 7, columns[0] == "apnic", columns[1] == "CN",
                  columns[2] == "ipv6" else { continue }
            guard let length = Int(columns[4]), (3...128).contains(length),
                  let status = columns.last, ["allocated", "assigned"].contains(status),
                  columns[3].utf8.count <= 48 else {
                // Malformed country rows cannot quietly vanish from a future
                // route plan; abort the entire candidate refresh instead.
                throw APNICIPv6Error.malformedCountryEntry
            }
            lines.append("\(columns[3])/\(length)")
            guard lines.count < 30_000 else { throw APNICIPv6Error.oversized }
        }
        guard lines.count >= 2 else { throw APNICIPv6Error.missingCountryData }
        return try IPv6RuleSet(text: lines.joined(separator: "\n"))
    }
}

public enum APNICIPv6Error: Error, Equatable {
    case oversized, missingCountryData, malformedCountryEntry
}

/// User-scoped IPv6 feed cache. The helper independently validates all data
/// before constructing a journaled route plan; cache writes never alter routes.
public actor APNICIPv6PreviewStore {
    public static let source = URL(
        string: "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest")!

    private let root: URL
    public init(root: URL) { self.root = root }

    public func cached() throws -> IPv6RuleSet? {
        try RuleCacheStore.read(root).ipv6.map { try IPv6RuleSet(text: $0) }
    }

    public func fetchCandidate() async throws -> IPv6RuleSet {
        let data = try await BoundedDownload.data(from: Self.source, maximumBytes: 7_999_999,
                                                  allowedHosts: ["ftp.apnic.net"], timeout: 30)
        guard data.count > 1000, let text = String(data: data, encoding: .utf8) else {
            throw APNICIPv6Error.missingCountryData
        }
        let candidate = try APNICIPv6Delegations.parse(text)
        guard candidate.routes.count >= 100 else {
            throw APNICIPv6Error.missingCountryData
        }
        if let previous = try cached() { try IPv6RuleSet.validateChange(previous: previous, next: candidate) }
        return candidate
    }
    public func commit(_ candidate: IPv6RuleSet) throws {
        let prepared = try RuleCacheStore.Prepared(root: root, ipv4: nil, ipv6: candidate)
        try prepared.publish()
    }
    public func refresh() async throws -> IPv6RuleSet { let value = try await fetchCandidate(); try commit(value); return value }
}

extension IPv6RuleSet {
    public static func validateChange(previous: Self, next: Self) throws {
        let old = previous.routes.count, count = next.routes.count
        let a = Set(previous.routes), b = Set(next.routes)
        guard count >= 100, count >= old * 80 / 100, count <= old * 120 / 100,
              a.symmetricDifference(b).count <= max(100, old / 3) else { throw RuleError.suspiciousChange }
    }
}
