import Foundation

public enum RoutingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case fullVPN = "Full VPN"
    case chinaDirect = "China Direct"
    public var id: String { rawValue }
}

public struct VPNProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var sourceFilename: String
    public var relativePath: String
    public var mode: RoutingMode
    public var importedAt: Date
    public init(id: UUID = UUID(), name: String, sourceFilename: String,
                relativePath: String, mode: RoutingMode = .original, importedAt: Date = Date()) {
        self.id = id; self.name = name; self.sourceFilename = sourceFilename
        self.relativePath = relativePath; self.mode = mode; self.importedAt = importedAt
    }
}

public struct IPv4CIDR: Hashable, Comparable, CustomStringConvertible, Sendable {
    public let network: UInt32
    public let prefix: Int
    public init(_ string: String) throws {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let bits = Int(parts[1]), (0...32).contains(bits),
              let address = Self.parseAddress(String(parts[0])) else { throw CIDRError.invalid(string) }
        let mask: UInt32 = bits == 0 ? 0 : UInt32.max << (32 - bits)
        network = address & mask
        prefix = bits
    }
    public var description: String { "\(Self.addressString(network))/\(prefix)" }
    public var netmask: String { Self.addressString(prefix == 0 ? 0 : UInt32.max << (32 - prefix)) }
    public func contains(_ address: UInt32) -> Bool {
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
        return (address & mask) == network
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.network == rhs.network ? lhs.prefix < rhs.prefix : lhs.network < rhs.network
    }
    public static func parseAddress(_ string: String) -> UInt32? {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty, octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = UInt8(octet) else { return nil }
            value = (value << 8) | UInt32(number)
        }
        return value
    }
    private static func addressString(_ address: UInt32) -> String {
        "\((address >> 24) & 255).\((address >> 16) & 255).\((address >> 8) & 255).\(address & 255)"
    }
}
public enum CIDRError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { "Invalid IPv4 CIDR" }
}
