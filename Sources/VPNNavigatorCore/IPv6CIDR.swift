import Foundation
import Darwin

/// IPv6 address and prefix handling, independent of the privileged route
/// executor. Network masks are canonicalized to prevent duplicate prefixes.
public struct IPv6CIDR: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let network: [UInt8]
    public let prefix: Int

    public init(_ text: String) throws {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]),
              (0...128).contains(bits),
              let raw = Self.parseAddress(String(parts[0])) else {
            throw IPv6RuleError.invalid(text)
        }
        self.prefix = bits
        self.network = Self.mask(raw, bits: bits)
    }

    public var description: String {
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { output in
            for (i, octet) in network.enumerated() { output[i] = octet }
        }
        var result = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let found = withUnsafePointer(to: &addr) {
            inet_ntop(AF_INET6, $0, &result, socklen_t(result.count))
        }
        return "\(found != nil ? String(cString: result) : "::")/\(prefix)"
    }

    public func contains(_ text: String) -> Bool {
        guard let parsed = Self.parseAddress(text) else { return false }
        return Self.mask(parsed, bits: prefix) == network
    }

    public func overlaps(_ other: IPv6CIDR) -> Bool {
        let bits = Swift.min(prefix, other.prefix)
        return Self.mask(network, bits: bits) == Self.mask(other.network, bits: bits)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.network == rhs.network ? lhs.prefix < rhs.prefix :
            lhs.network.lexicographicallyPrecedes(rhs.network)
    }

    public static func parseAddress(_ input: String) -> [UInt8]? {
        // Reject scoped link-local addresses: interface scopes are not a part
        // of portable route rules and must never be accepted from a remote feed.
        guard !input.contains("%"), !input.isEmpty else { return nil }
        var addr = in6_addr()
        let status = input.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard status == 1 else { return nil }
        return withUnsafeBytes(of: &addr) { Array($0) }
    }

    public static func addressString(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        var addr = in6_addr()
        withUnsafeMutableBytes(of: &addr) { $0.copyBytes(from: bytes) }
        var result = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &addr) { inet_ntop(AF_INET6, $0, &result, socklen_t(result.count)) } == nil ? "" : String(cString: result)
    }
    public init(from decoder: Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(description) }
    public var address: String { Self.addressString(network) }
    public var netmask: String { Self.addressString(Self.mask([UInt8](repeating: 255, count: 16), bits: prefix)) }
    public func children() throws -> [Self] {
        guard prefix < 128 else { return [] }
        var upper = network; upper[prefix / 8] |= UInt8(1 << (7 - prefix % 8))
        return try [Self(address + "/\(prefix + 1)"), Self(Self.addressString(upper) + "/\(prefix + 1)")]
    }

    private static func mask(_ bytes: [UInt8], bits: Int) -> [UInt8] {
        var result = bytes
        for i in result.indices {
            let remaining = bits - i * 8
            if remaining <= 0 { result[i] = 0 }
            else if remaining < 8 { result[i] &= UInt8.max << (8 - remaining) }
        }
        return result
    }
}

public enum IPv6RuleError: Error, Equatable {
    case invalid(String), specialPurpose(String), tooLarge, empty
}

/// Untrusted registry-feed parser. Parsing or caching never changes OS routes.
public struct IPv6RuleSet: Sendable {
    public let routes: [IPv6CIDR]

    private static let publiclyRoutable = try! IPv6CIDR("2000::/3")
    private static let reserved = [
        "::/128", "::1/128", "::ffff:0:0/96", "fc00::/7",
        "fe80::/10", "ff00::/8", "2001:db8::/32",
        "2001:10::/28", "2001:20::/28", "2001:2::/48"
    ].compactMap { try? IPv6CIDR($0) }

    public init(text: String) throws {
        guard text.utf8.count <= 2_000_000 else { throw IPv6RuleError.tooLarge }
        var values = Set<IPv6CIDR>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let cidr = try IPv6CIDR(line)
            guard cidr.prefix >= 3,
                  Self.publiclyRoutable.overlaps(cidr),
                  Self.reserved.allSatisfy({ !$0.overlaps(cidr) }) else {
                throw IPv6RuleError.specialPurpose(line)
            }
            values.insert(cidr)
            guard values.count <= 30_000 else { throw IPv6RuleError.tooLarge }
        }
        guard !values.isEmpty else { throw IPv6RuleError.empty }
        routes = values.sorted()
    }

    public func contains(_ address: String) -> Bool {
        routes.contains { $0.contains(address) }
    }
}
