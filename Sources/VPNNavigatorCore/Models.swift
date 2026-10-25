import Foundation

public enum RoutingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case fullVPN = "Full VPN"
    case chinaDirect = "China Direct"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .original: return "原始配置"
        case .fullVPN: return "全局路由"
        case .chinaDirect: return "规则路由"
        }
    }
}

public struct VPNProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var sourceFilename: String
    public var relativePath: String
    public var mode: RoutingMode
    public var importedAt: Date
    public var group: String
    public var notes: String
    public var customRules: [CustomRouteRule]
    public var isFavorite: Bool
    /// Separate from the stable profile ID so identity changes cannot reuse
    /// credentials, even when the app exits immediately after an update.
    public var credentialID: UUID

    public init(id: UUID = UUID(), name: String, sourceFilename: String,
                relativePath: String, mode: RoutingMode = .original, importedAt: Date = Date(),
                group: String = "Personal", notes: String = "", isFavorite: Bool = false, customRules: [CustomRouteRule] = []) {
        self.id = id; self.name = name; self.sourceFilename = sourceFilename
        self.relativePath = relativePath; self.mode = mode; self.importedAt = importedAt
        self.group = group; self.notes = notes; self.isFavorite = isFavorite; self.customRules = customRules
        self.credentialID = id
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, sourceFilename, relativePath, mode, importedAt, group, notes, isFavorite, customRules, credentialID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        mode = try container.decode(RoutingMode.self, forKey: .mode)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        group = try container.decodeIfPresent(String.self, forKey: .group) ?? "Personal"
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        customRules = try container.decodeIfPresent([CustomRouteRule].self, forKey: .customRules) ?? []
        credentialID = try container.decodeIfPresent(UUID.self, forKey: .credentialID) ?? id
    }
}

public struct IPv4CIDR: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
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
    /// Two CIDR networks overlap if the shorter prefix matches both.
    public func overlaps(_ other: IPv4CIDR) -> Bool {
        let sharedBits = Swift.min(prefix, other.prefix)
        let mask: UInt32 = sharedBits == 0 ? 0 : UInt32.max << (32 - sharedBits)
        return (network & mask) == (other.network & mask)
    }
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
